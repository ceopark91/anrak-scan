import SwiftUI

// MARK: - 손그림 → 캐드처럼 보정 (웹 안락실측 SK와 같은 계산)
// 손으로 그린 선을 꺾이는 점만 남기고(RDP) 각 변을 90°(가깝으면 45°)로 맞춘 뒤,
// 잰 길이 + 그림 비율로 모자란 길이를 풀어 도형을 닫는다 (가중 최소제곱, 닫힘 조건 2개).

struct SkSeg { var dir: Double; var px: Double; var len: Int = 0; var prior = false; var ops: [AOp] = [] }   // prior: px가 이미 mm(스캔 값)
struct SkResult { var lens: [Int]; var auto: [Bool]; var ok: Bool; var msg: String }

enum SK {
    static func norm(_ a: Double) -> Double { var a = a; while a > 180 { a -= 360 }; while a <= -180 { a += 360 }; return a }

    static func rdp(_ p: [CGPoint], _ eps: Double) -> [CGPoint] {
        guard p.count >= 3 else { return p }
        let a = p[0], b = p[p.count - 1]
        let L = max(1e-9, hypot(b.x - a.x, b.y - a.y))
        var dm = -1.0, idx = 0
        for i in 1..<(p.count - 1) {
            let q = p[i]
            let d = abs((b.x - a.x) * (a.y - q.y) - (a.x - q.x) * (b.y - a.y)) / L
            if d > dm { dm = d; idx = i }
        }
        if dm > eps {
            let l = rdp(Array(p[0...idx]), eps), r = rdp(Array(p[idx...]), eps)
            return Array(l.dropLast()) + r
        }
        return [a, b]
    }

    static func diag(_ p: [CGPoint]) -> Double {
        guard let x0 = p.map(\.x).min(), let x1 = p.map(\.x).max(), let y0 = p.map(\.y).min(), let y1 = p.map(\.y).max() else { return 0 }
        return hypot(x1 - x0, y1 - y0)
    }

    static func fromStroke(_ raw: [CGPoint]) -> [SkSeg]? {
        guard raw.count >= 4 else { return nil }
        let d = diag(raw); guard d >= 30 else { return nil }
        var q = rdp(raw, d * 0.035)
        if q.count > 2, hypot(q[0].x - q[q.count - 1].x, q[0].y - q[q.count - 1].y) < d * 0.12 { q.removeLast() }
        guard q.count >= 3 else { return nil }
        return fromCorners(q, d)
    }

    static func fromCorners(_ input: [CGPoint], _ diag: Double, taps: Bool = false) -> [SkSeg]? {
        var q = input
        var s = 0.0
        for i in 0..<q.count { let a = q[i], b = q[(i + 1) % q.count]; s += Double(a.x * b.y - b.x * a.y) }
        if s < 0 { q = [q[0]] + q.dropFirst().reversed() }
        var segs = q.indices.map { i -> SkSeg in
            let a = q[i], b = q[(i + 1) % q.count]
            return SkSeg(dir: Double(atan2(b.y - a.y, b.x - a.x)) * 180 / Double.pi, px: Double(hypot(b.x - a.x, b.y - a.y)))
        }
        var snapped = Array(repeating: true, count: segs.count)
        for i in segs.indices {
            let g = segs[i].dir, r90 = (g / 90).rounded() * 90, r45 = (g / 45).rounded() * 45
            if abs(g - r90) <= 20 { segs[i].dir = norm(r90) } else if abs(g - r45) <= 25 { segs[i].dir = norm(r45) } else { snapped[i] = false }
        }
        func isAxis(_ d: Double) -> Bool { abs(d / 90 - (d / 90).rounded()) < 0.01 }
        // 정리: 같은 방향은 합치고, 되돌아간 선(겹친 시작·끝)은 빼고, 짧은 변은 없앰
        var changed = true
        while changed && segs.count > 3 {
            changed = false
            for i in segs.indices {
                let j = (i + 1) % segs.count
                let d = abs(norm(segs[i].dir - segs[j].dir))
                if d < 0.5 { segs[i].px += segs[j].px; segs.remove(at: j); snapped.remove(at: j); changed = true; break }
                if abs(d - 180) < 0.5 {
                    let net = segs[i].px - segs[j].px
                    if net < 0 { segs[i].dir = segs[j].dir; snapped[i] = snapped[j] }
                    segs[i].px = abs(net); segs.remove(at: j); snapped.remove(at: j); changed = true; break
                }
            }
            if changed { continue }
            var mi = -1
            for (i, g) in segs.enumerated() {
                let short = g.px < diag * (taps ? 0.02 : 0.08) || (!taps && !snapped[i] && g.px < diag * 0.15) || (!taps && !isAxis(g.dir) && g.px < diag * 0.12)
                if short && (mi < 0 || g.px < segs[mi].px) { mi = i }
            }
            if mi >= 0 { segs.remove(at: mi); snapped.remove(at: mi); changed = true }
        }
        // 누가 봐도 네모: 감싸는 네모를 거의 채우고 모두 가로·세로면 네모로
        let xs = q.map { Double($0.x) }, ys = q.map { Double($0.y) }
        let w = xs.max()! - xs.min()!, h = ys.max()! - ys.min()!
        let fillR = abs(s) / 2 / max(1, w * h)
        if !taps, fillR > 0.97, segs.allSatisfy({ isAxis($0.dir) }), segs.count != 4 {
            segs = [SkSeg(dir: 0, px: w), SkSeg(dir: 90, px: h), SkSeg(dir: 180, px: w), SkSeg(dir: -90, px: h)]
        }
        return segs.count >= 3 ? segs : nil
    }

    static func solve(_ segs: [SkSeg]) -> SkResult {
        let n = segs.count
        let u = segs.map { (cos($0.dir * .pi / 180), sin($0.dir * .pi / 180)) }
        let K = segs.indices.filter { segs[$0].len > 0 }, U = segs.indices.filter { segs[$0].len <= 0 }
        let allPrior = segs.allSatisfy { $0.prior }
        guard !K.isEmpty || allPrior else { return SkResult(lens: Array(repeating: 0, count: n), auto: Array(repeating: true, count: n), ok: false, msg: "벽 하나 이상 길이를 넣어 주세요") }
        let scale = allPrior ? 1 : Double(K.reduce(0) { $0 + segs[$1].len }) / K.reduce(0.0) { $0 + segs[$1].px }
        var lens = segs.map { Double(max(0, $0.len)) }
        let V = U.isEmpty ? K : U
        let x0 = V.map { U.isEmpty ? lens[$0] : segs[$0].px * scale }
        let w = x0.map { max(1, $0) * max(1, $0) }
        var b = (0.0, 0.0)
        for i in 0..<n where !V.contains(i) { b.0 -= lens[i] * u[i].0; b.1 -= lens[i] * u[i].1 }
        var r = b
        for (k, i) in V.enumerated() { r.0 -= u[i].0 * x0[k]; r.1 -= u[i].1 * x0[k] }
        let gap0 = hypot(r.0, r.1)
        var m00 = 0.0, m01 = 0.0, m11 = 0.0
        for (k, i) in V.enumerated() { m00 += w[k] * u[i].0 * u[i].0; m01 += w[k] * u[i].0 * u[i].1; m11 += w[k] * u[i].1 * u[i].1 }
        let det = m00 * m11 - m01 * m01
        var x = x0
        if abs(det) > 1e-9 * max(1, m00 * m11) {
            let l0 = (m11 * r.0 - m01 * r.1) / det, l1 = (-m01 * r.0 + m00 * r.1) / det
            x = x0.enumerated().map { k, v in v + w[k] * (u[V[k]].0 * l0 + u[V[k]].1 * l1) }
        } else if m00 + m11 > 0 {
            let d = u[V[0]], t = (r.0 * d.0 + r.1 * d.1) / (m00 + m11)
            x = x0.enumerated().map { k, v in v + w[k] * t * (u[V[k]].0 * d.0 + u[V[k]].1 * d.1) }
        }
        for (k, i) in V.enumerated() { lens[i] = (x[k] / 10).rounded() * 10 }
        let out = lens.map { Int($0) }
        let bad = out.contains { $0 <= 0 }
        let msg: String
        if bad { msg = "길이가 맞지 않습니다. 그림이나 넣은 치수를 확인해 주세요" }
        else if U.isEmpty && gap0 > 60 { msg = "잰 치수끼리 \(Int(gap0))mm 어긋나 고르게 나눴습니다. 한 번 더 재 보세요" }
        else if U.isEmpty { msg = gap0 > 5 ? "잰 치수 오차 \(Int(gap0))mm를 고르게 나눠 닫았습니다" : "잰 치수로 딱 맞게 닫혔습니다" }
        else if allPrior { msg = K.isEmpty ? "스캔 값입니다. 번호를 눌러 잰 길이로 고치세요" : "고친 \(K.count)개 벽에 맞춰 나머지를 다시 맞췄습니다" }
        else { msg = "\(U.count)개 벽은 그림 비율과 닫힘으로 자동 계산했습니다" }
        return SkResult(lens: out, auto: segs.indices.map { V.contains($0) }, ok: !bad, msg: msg)
    }

    static func walls(_ segs: [SkSeg], _ lens: [Int]) -> [AWall] {
        segs.indices.map { i in
            let t = (norm(segs[(i + 1) % segs.count].dir - segs[i].dir) * 10).rounded() / 10
            return AWall(len: lens[i], turn: abs(t - 90) < 0.05 ? "R" : abs(t + 90) < 0.05 ? "L" : String(t), ops: [])
        }
    }
}

// MARK: - 손그림 화면

struct OpHit: Equatable { var wall: Int; var k: Int; var a: CGPoint; var b: CGPoint }

struct SketchScreen: View {
    var editRoomId: String? = nil      // 있으면 그 방(스캔·손그림)을 번호 눌러 고치기
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @ObservedObject var laser = LaserLink.shared
    @State private var raw: [CGPoint] = []
    @State private var cur: [CGPoint] = []
    @State private var taps: [CGPoint] = []
    @State private var segs: [SkSeg]? = nil
    @State private var sel = 0
    @State private var lenText = ""
    @State private var ceil = 2300
    @State private var name = "거실"
    @State private var msg: String?
    @State private var labelPos: [CGPoint] = []
    @State private var osel: Int? = nil              // 고른 벽의 몇 번째 문·창
    @State private var opHits: [OpHit] = []
    @FocusState private var focus: Bool

    var result: SkResult? { segs.map { SK.solve($0) } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                GeometryReader { geo in
                    ZStack {
                        Color.white
                        Canvas { ctx, size in drawGrid(ctx, size); draw(ctx, size) }
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in if segs == nil { cur.append(v.location) } }
                        .onEnded { v in end(v, geo.size) })
                }
                bottom
            }
            .background(Color(white: 0.96))
            .navigationTitle(editRoomId == nil ? "손그림 방" : "도면 고치기").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("닫기") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button("다시 그리기") { raw = []; cur = []; taps = []; segs = nil; msg = nil } }
            }
            .onAppear { if segs == nil { loadRoom() } }
            .onChange(of: laser.seq) { _, _ in
                guard let v = laser.lastMM, segs != nil else { return }
                segs![sel].len = v; next()
            }
        }
    }

    // 그리기 끝 (손 뗌)
    func end(_ v: DragGesture.Value, _ size: CGSize) {
        if segs != nil { pick(v.location); return }
        let moved = hypot(v.translation.width, v.translation.height)
        if moved < 8 {
            taps.append(v.location)
            if taps.count >= 4, hypot(taps[0].x - v.location.x, taps[0].y - v.location.y) < 22 { taps.removeLast(); finish() }
        } else {
            raw += cur
            if raw.count > 20, let a = raw.first, hypot(a.x - v.location.x, a.y - v.location.y) < max(30, SK.diag(raw) * 0.12) { cur = []; finish(); return }
        }
        cur = []
    }

    func finish() {
        let s = taps.count >= 3 ? SK.fromCorners(taps, max(400, SK.diag(taps)), taps: true) : SK.fromStroke(raw)
        guard let s else { msg = "모양을 못 알아봤습니다. 방 둘레를 한 바퀴 크게 그려 주세요"; raw = []; taps = []; return }
        segs = s; sel = 0; lenText = ""; msg = nil; focus = true
    }

    /// 잘못 그린 벽 지우기: 고른 벽을 빼고 같은 방향으로 이어지는 벽은 합침
    func deleteWall() {
        guard var s = segs else { return }
        s.remove(at: sel); osel = nil
        var ch = true
        while ch && s.count > 3 {
            ch = false
            for i in s.indices {
                let j = (i + 1) % s.count
                if abs(SK.norm(s[i].dir - s[j].dir)) < 0.5 {
                    let base = s[i].len
                    s[i].ops += s[j].ops.map { var o = $0; o.off += base; return o }
                    s[i].px += s[j].px
                    s[i].len = (s[i].len > 0 && s[j].len > 0) ? s[i].len + s[j].len : 0
                    s.remove(at: j); ch = true; break
                }
            }
        }
        if s.count < 3 { segs = nil; raw = []; taps = []; msg = "벽이 3개보다 적어 다시 그려 주세요"; return }
        segs = s; sel = min(sel, s.count - 1); lenText = s[sel].len > 0 ? "\(s[sel].len)" : ""
    }

    func next() {
        guard let s = segs else { return }
        if let j = s.indices.first(where: { $0 > sel && s[$0].len <= 0 }) ?? s.indices.first(where: { s[$0].len <= 0 }) { sel = j } else { sel = (sel + 1) % s.count }
        osel = nil
        lenText = s[sel].len > 0 ? "\(s[sel].len)" : ""
    }

    func pick(_ p: CGPoint) {
        // 문·창 먼저
        var ob: OpHit? = nil, od = 18.0
        for h in opHits {
            let dx = h.b.x - h.a.x, dy = h.b.y - h.a.y, L2 = max(1, dx * dx + dy * dy)
            let t = max(0, min(1, ((p.x - h.a.x) * dx + (p.y - h.a.y) * dy) / L2))
            let d = hypot(p.x - h.a.x - dx * t, p.y - h.a.y - dy * t)
            if d < od { od = d; ob = h }
        }
        if let ob, let s = segs { sel = ob.wall; osel = ob.k; lenText = s[sel].len > 0 ? "\(s[sel].len)" : ""; return }
        var best = -1, bd = 44.0
        for (i, q) in labelPos.enumerated() { let d = hypot(q.x - p.x, q.y - p.y); if d < bd { bd = d; best = i } }
        if best >= 0, let s = segs { if best != sel { osel = nil }; sel = best; lenText = s[best].len > 0 ? "\(s[best].len)" : ""; focus = true }
    }

    // 보정된 모양 점 (mm 또는 그림 비율)
    func poly() -> [CGPoint] {
        guard let s = segs else { return [] }
        let r = result, has = r.map { $0.lens.allSatisfy { $0 > 0 } } ?? false
        // 아직 잰 값이 없으면 그림 길이로 닫아서 보여 줌
        let shown = has ? r!.lens : SK.solve(s.map { SkSeg(dir: $0.dir, px: $0.px, len: Int($0.px.rounded())) }).lens
        var x = 0.0, y = 0.0; var P = [CGPoint.zero]
        for (i, g) in s.enumerated() {
            let L = shown[i] > 0 ? Double(shown[i]) : g.px
            x += cos(g.dir * .pi / 180) * L; y += sin(g.dir * .pi / 180) * L; P.append(CGPoint(x: x, y: y))
        }
        return P
    }

    /// 화면에 쓰는 벽 길이(mm): 다 풀렸으면 결과, 아니면 그림 비율
    func shownLens() -> [Int] {
        guard let s = segs else { return [] }
        if let r = result, r.lens.allSatisfy({ $0 > 0 }) { return r.lens }
        return SK.solve(s.map { SkSeg(dir: $0.dir, px: $0.px, len: Int($0.px.rounded())) }).lens
    }

    func addOp(_ kind: String) {
        guard segs != nil else { return }
        let L = shownLens()[sel] > 0 ? shownLens()[sel] : 1800
        let w = kind == "door" ? 900 : 1200
        segs![sel].ops.append(AOp(id: uid(), kind: kind, off: max(0, Int((Double(L - w) / 2 / 50).rounded()) * 50), w: w,
                                  h: kind == "door" ? 2100 : 1200, sill: kind == "door" ? 0 : 900))
        osel = segs![sel].ops.count - 1
    }

    func opBinding(_ key: WritableKeyPath<AOp, Int>) -> Binding<Int> {
        Binding(get: { guard let s = segs, let k = osel, k < s[sel].ops.count else { return 0 }; return s[sel].ops[k][keyPath: key] },
                set: { v in guard segs != nil, let k = osel, k < segs![sel].ops.count else { return }; segs![sel].ops[k][keyPath: key] = v })
    }

    func drawGrid(_ ctx: GraphicsContext, _ size: CGSize) {
        var p = Path()
        stride(from: 0.0, to: size.width, by: 24).forEach { p.move(to: CGPoint(x: $0, y: 0)); p.addLine(to: CGPoint(x: $0, y: size.height)) }
        stride(from: 0.0, to: size.height, by: 24).forEach { p.move(to: CGPoint(x: 0, y: $0)); p.addLine(to: CGPoint(x: size.width, y: $0)) }
        ctx.stroke(p, with: .color(Color(white: 0.92)), lineWidth: 1)
    }

    func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let acc = Color(red: 0.25, green: 0.32, blue: 0.28)
        guard let s = segs else {
            func path(_ a: [CGPoint]) { guard a.count > 1 else { return }; var p = Path(); p.addLines(a); ctx.stroke(p, with: .color(.gray), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)) }
            path(raw); path(cur)
            for t in taps { ctx.fill(Path(ellipseIn: CGRect(x: t.x - 5, y: t.y - 5, width: 10, height: 10)), with: .color(acc)) }
            if taps.count > 1 { var p = Path(); p.addLines(taps); ctx.stroke(p, with: .color(acc), lineWidth: 2) }
            if raw.isEmpty && cur.isEmpty && taps.isEmpty {
                ctx.draw(Text("방 둘레를 손가락으로 한 바퀴 대충 그리세요\n(또는 모서리를 차례로 눌러 점 찍기)").font(.subheadline).foregroundColor(.gray),
                         at: CGPoint(x: size.width / 2, y: size.height / 2))
            }
            return
        }
        let P = poly(), r = result
        let xs = P.map(\.x), ys = P.map(\.y)
        let pad = min(80.0, size.width * 0.18)
        let k = min((size.width - pad * 2) / max(1, xs.max()! - xs.min()!), (size.height - pad * 2) / max(1, ys.max()! - ys.min()!))
        let ox = (size.width - (xs.max()! - xs.min()!) * k) / 2 - xs.min()! * k, oy = (size.height - (ys.max()! - ys.min()!) * k) / 2 - ys.min()! * k
        let Q = P.map { CGPoint(x: $0.x * k + ox, y: $0.y * k + oy) }
        var fill = Path(); fill.addLines(Array(Q.prefix(s.count))); fill.closeSubpath()
        ctx.fill(fill, with: .color(Color(red: 0.90, green: 0.93, blue: 0.91)))
        var labels = Array(repeating: CGPoint.zero, count: s.count)
        let has = r.map { $0.lens.allSatisfy { $0 > 0 } } ?? false
        for i in s.indices {
            let a = Q[i], b = Q[i + 1]
            var p = Path(); p.move(to: a); p.addLine(to: b)
            ctx.stroke(p, with: .color(i == sel ? acc : .black), style: StrokeStyle(lineWidth: i == sel ? 5 : 3, lineCap: .round))
        }
        // 문·창: 벽을 끊고 문은 여닫는 호, 창은 두 줄. 고른 벽은 기준 모서리와 치수 표시
        let SL = shownLens(); var hits: [OpHit] = []
        for i in s.indices where !s[i].ops.isEmpty && SL[i] > 0 {
            let a = Q[i], b = Q[i + 1], dx = b.x - a.x, dy = b.y - a.y, Ls = max(1, hypot(dx, dy))
            let tx = dx / Ls, ty = dy / Ls, nx = -ty, ny = tx     // 방 안쪽
            for (k, o) in s[i].ops.enumerated() {
                let s0 = max(0, min(1, Double(o.off) / Double(SL[i]))), s1 = max(0, min(1, Double(o.off + o.w) / Double(SL[i])))
                let p0 = CGPoint(x: a.x + dx * s0, y: a.y + dy * s0), p1 = CGPoint(x: a.x + dx * s1, y: a.y + dy * s1)
                let on = i == sel && osel == k, col: Color = on ? acc : .black
                var gap = Path(); gap.move(to: p0); gap.addLine(to: p1)
                ctx.stroke(gap, with: .color(.white), style: StrokeStyle(lineWidth: 7, lineCap: .butt))
                for q in [p0, p1] { var t = Path(); t.move(to: CGPoint(x: q.x - nx * 5, y: q.y - ny * 5)); t.addLine(to: CGPoint(x: q.x + nx * 5, y: q.y + ny * 5)); ctx.stroke(t, with: .color(col), lineWidth: on ? 2.5 : 1.6) }
                let ww = hypot(p1.x - p0.x, p1.y - p0.y)
                if o.kind == "door" {
                    var leaf = Path(); leaf.move(to: p0); leaf.addLine(to: CGPoint(x: p0.x + nx * ww, y: p0.y + ny * ww))
                    ctx.stroke(leaf, with: .color(col), lineWidth: on ? 2.5 : 1.6)
                    let st = atan2(ny, nx), en = atan2(ty, tx); var d = en - st
                    while d > .pi { d -= 2 * .pi }; while d < -.pi { d += 2 * .pi }
                    var arc = Path(); arc.addArc(center: p0, radius: ww, startAngle: .radians(st), endAngle: .radians(st + d), clockwise: d < 0)
                    ctx.stroke(arc, with: .color(col), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                } else {
                    for d in [-2.5, 2.5] { var w = Path(); w.move(to: CGPoint(x: p0.x + nx * d, y: p0.y + ny * d)); w.addLine(to: CGPoint(x: p1.x + nx * d, y: p1.y + ny * d)); ctx.stroke(w, with: .color(col), lineWidth: 1.4) }
                }
                hits.append(OpHit(wall: i, k: k, a: p0, b: p1))
                if i == sel {
                    let off = o.kind == "door" ? ww * 0.5 + 16 : 18
                    let m = CGPoint(x: (p0.x + p1.x) / 2 + nx * off, y: (p0.y + p1.y) / 2 + ny * off)
                    let t = ctx.resolve(Text("\(o.kind == "door" ? "문" : "창") \(mm(o.off)) 띄우고 폭 \(mm(o.w))").font(.caption2.weight(.semibold)).foregroundColor(on ? .white : .black))
                    let sz = t.measure(in: CGSize(width: 300, height: 30)); let box = CGRect(x: m.x - sz.width / 2 - 6, y: m.y - 11, width: sz.width + 12, height: 22)
                    ctx.fill(Path(roundedRect: box, cornerRadius: 11), with: .color(on ? acc : .white))
                    ctx.stroke(Path(roundedRect: box, cornerRadius: 11), with: .color(Color(white: 0.85)), lineWidth: 1)
                    ctx.draw(t, at: m)
                }
            }
        }
        if sel < s.count, !s[sel].ops.isEmpty {
            let a = Q[sel], b = Q[sel + 1], L = max(1, hypot(b.x - a.x, b.y - a.y)), ux = (b.x - a.x) / L, uy = (b.y - a.y) / L
            ctx.fill(Path(ellipseIn: CGRect(x: a.x - 6, y: a.y - 6, width: 12, height: 12)), with: .color(acc))
            ctx.draw(Text("기준").font(.caption2.weight(.semibold)).foregroundColor(acc), at: CGPoint(x: a.x - ux * 18 + uy * 18, y: a.y - uy * 18 - ux * 18))
        }
        DispatchQueue.main.async { if hits != opHits { opHits = hits } }
        // 이름표: 짧은 벽부터 겹치지 않는 자리를 찾고, 멀리 밀리면 벽까지 지시선
        var boxes: [CGRect] = []
        let order = s.indices.sorted { hypot(Q[$0 + 1].x - Q[$0].x, Q[$0 + 1].y - Q[$0].y) < hypot(Q[$1 + 1].x - Q[$1].x, Q[$1 + 1].y - Q[$1].y) }
        var drawn: [(Int, GraphicsContext.ResolvedText, CGRect, CGPoint, Bool)] = []
        for i in order {
            let g = s[i], a = Q[i], b = Q[i + 1]
            let L = max(1, hypot(b.x - a.x, b.y - a.y)), nx = (b.y - a.y) / L, ny = -(b.x - a.x) / L, tx = (b.x - a.x) / L, ty = (b.y - a.y) / L
            let m = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let val = g.len > 0 ? mm(g.len) : has ? "\(g.prior ? "스캔" : "자동") \(mm(r!.lens[i]))" : "?"
            let t = ctx.resolve(Text("\(i + 1)  \(val)").font(.caption.weight(g.len > 0 ? .bold : .regular)).foregroundColor(i == sel ? .white : g.len > 0 ? .black : .gray))
            let sz = t.measure(in: CGSize(width: 300, height: 40)); let bw = sz.width + 16
            var cands: [(CGFloat, CGFloat)] = []
            for d in [22.0, 46, 70, 96, 124, 154] { for k in [0.0, -0.6, 0.6, -1.2, 1.2] { cands.append((d, k * bw)) } }
            cands += [(-30, 0), (-56, 0)]
            var pick: (CGRect, Bool)? = nil
            for (d, k) in cands {
                let c = CGPoint(x: m.x + nx * d + tx * k, y: m.y + ny * d + ty * k)
                let box = CGRect(x: c.x - bw / 2, y: c.y - 12, width: bw, height: 24)
                let inside = box.minX > 2 && box.minY > 2 && box.maxX < size.width - 2 && box.maxY < size.height - 2
                if inside && !boxes.contains(where: { $0.insetBy(dx: -4, dy: -4).intersects(box) }) { pick = (box, d > 30 || abs(k) > 1); break }
            }
            let box = pick?.0 ?? CGRect(x: min(size.width - bw - 4, max(4, m.x + nx * 22 - bw / 2)), y: min(size.height - 28, max(4, m.y + ny * 22 - 12)), width: bw, height: 24)
            boxes.append(box); labels[i] = CGPoint(x: box.midX, y: box.midY)
            drawn.append((i, t, box, m, pick?.1 ?? false))
        }
        for (i, t, box, m, lead) in drawn {
            if lead {
                var p = Path(); p.move(to: m); p.addLine(to: CGPoint(x: box.midX, y: box.midY))
                ctx.stroke(p, with: .color(i == sel ? acc : .gray), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                ctx.fill(Path(ellipseIn: CGRect(x: m.x - 3, y: m.y - 3, width: 6, height: 6)), with: .color(i == sel ? acc : .gray))
            }
            ctx.fill(Path(roundedRect: box, cornerRadius: 12), with: .color(i == sel ? acc : .white))
            ctx.stroke(Path(roundedRect: box, cornerRadius: 12), with: .color(Color(white: 0.85)), lineWidth: 1)
            ctx.draw(t, at: CGPoint(x: box.midX, y: box.midY))
        }
        DispatchQueue.main.async { if labels != labelPos { labelPos = labels } }
    }

    var bottom: some View {
        VStack(spacing: 10) {
            if let m = msg { Text(m).font(.caption).foregroundStyle(.red) }
            if segs == nil {
                HStack(spacing: 10) {
                    Button { if !taps.isEmpty { taps.removeLast() } else { raw = [] } } label: { Text("되돌리기").frame(maxWidth: .infinity).padding(.vertical, 13) }
                        .background(Color(white: 0.93), in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(.black)
                    Button { finish() } label: { Text("다 그렸어요").fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 13) }
                        .background(Color.black, in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(.white)
                        .disabled(raw.count < 10 && taps.count < 3)
                }
                Text("대충 그려도 직각·45°로 반듯하게 맞춰 줍니다").font(.caption).foregroundStyle(.secondary)
            } else if let s = segs {
                HStack(spacing: 8) {
                    Text("\(sel + 1)번 벽").fontWeight(.semibold)
                    TextField(result.map { $0.lens[sel] > 0 ? "자동 \($0.lens[sel])" : "길이 mm" } ?? "길이 mm", text: $lenText)
                        .keyboardType(.numberPad).focused($focus)
                        .padding(10).background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                        .onChange(of: lenText) { _, v in if segs != nil, sel < s.count { segs![sel].len = Int(v.filter(\.isNumber)) ?? 0 } }
                    Button("다음") { next() }.buttonStyle(.bordered)
                    Button("지우기") { deleteWall() }.buttonStyle(.bordered).tint(.red)
                    if laser.connected { Button("측정") { laser.trigger() }.buttonStyle(.bordered) }
                }
                HStack(spacing: 6) {
                    Button("+ 문") { addOp("door") }.buttonStyle(.bordered)
                    Button("+ 창") { addOp("window") }.buttonStyle(.bordered)
                    if sel < s.count {
                        ForEach(Array(s[sel].ops.enumerated()), id: \.offset) { k, o in
                            Button("\(o.kind == "door" ? "문" : "창")\(k + 1)") { osel = k }
                                .buttonStyle(.bordered).tint(osel == k ? .black : .gray)
                        }
                        if s[sel].ops.isEmpty { Text("문·창이 있으면 눌러 넣기").font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 0)
                }
                if let k = osel, sel < s.count, k < s[sel].ops.count {
                    HStack(alignment: .bottom, spacing: 6) {
                        opField("기준 모서리에서", \.off)
                        opField("폭", \.w)
                        opField("높이", \.h)
                        if s[sel].ops[k].kind == "window" { opField("바닥에서", \.sill) }
                        Button("빼기") { segs![sel].ops.remove(at: k); osel = nil }.buttonStyle(.bordered).tint(.red)
                    }
                }
                HStack(spacing: 8) {
                    Text("천장고").font(.subheadline)
                    TextField("2300", value: $ceil, format: .number).keyboardType(.numberPad).frame(width: 70)
                        .padding(8).background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                    Text(result?.msg ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer(minLength: 0)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) { ForEach(roomTypes, id: \.self) { t in
                        Button(t) { name = t }.font(.subheadline).padding(.horizontal, 10).padding(.vertical, 6)
                            .background(name == t ? Color.black : Color.white, in: Capsule()).foregroundStyle(name == t ? .white : .black)
                    } }
                }
                Button { save() } label: { Text(editRoomId == nil ? "이 방 저장" : "고친 도면 저장").fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 13) }
                    .background(result?.ok == true ? Color.black : Color.gray, in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(.white)
                    .disabled(result?.ok != true)
            }
        }
        .padding(14)
        .background(Color(white: 0.96))
    }

    func opField(_ label: String, _ key: WritableKeyPath<AOp, Int>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            TextField("0", value: opBinding(key), format: .number).keyboardType(.numberPad)
                .padding(8).background(Color.white, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    /// 이미 있는 방 → 고치기 화면
    func loadRoom() {
        guard let id = editRoomId, let r = store.site.rooms.first(where: { $0.id == id }) else { return }
        var a = r.rot; var list: [SkSeg] = []
        for w in r.walls { list.append(SkSeg(dir: SK.norm(a), px: Double(w.len), len: 0, prior: true, ops: w.ops)); a += w.turnDeg }
        segs = list; name = r.name; ceil = r.ceil; sel = 0; lenText = ""
    }

    func clampOps(_ ops: [AOp], _ len: Int) -> [AOp] {
        ops.map { var o = $0; o.w = min(o.w, len); o.off = max(0, min(o.off, len - o.w)); return o }
    }

    func save() {
        guard let s = segs, let r = result, r.ok else { return }
        if let id = editRoomId, let i = store.site.rooms.firstIndex(where: { $0.id == id }) {
            var room = store.site.rooms[i]
            var walls = SK.walls(s, r.lens)
            for k in walls.indices { walls[k].ops = clampOps(s[k].ops, walls[k].len) }
            room.walls = walls; room.rot = (s[0].dir * 10).rounded() / 10; room.name = name
            if (1500...6000).contains(ceil) { room.ceil = ceil }
            store.site.rooms[i] = room
            dismiss(); return
        }
        let room = ScanRoom(id: uid(), name: name, sessionId: "sketch_" + uid(), x: 0, y: 0, rot: (s[0].dir * 10).rounded() / 10,
                            ceil: (1500...6000).contains(ceil) ? ceil : 2300, walls: SK.walls(s, r.lens).enumerated().map { k, w in var w = w; w.ops = clampOps(s[k].ops, w.len); return w }, usdz: nil, date: Date())
        store.add(room)
        dismiss()
    }
}
