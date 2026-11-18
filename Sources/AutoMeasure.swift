import SwiftUI
import ARKit
import SceneKit

// MARK: - 쏘면 알아서 벽에 들어가기
// 1) 카메라가 찾은 세로 벽면(ARPlaneAnchor)을 도면 벽과 겹쳐 폰 위치를 도면 위에 놓는다(자동 맞춤).
// 2) 폰이 향한 앞 벽과 등 뒤 벽을 찾고, 레이저(또는 줄자) 값이 오면 "두 벽 사이 거리 = 값" 조건으로
//    방 전체 벽 길이를 다시 맞춘다(닫힘 2개 + 잰 거리 조건들, 원래 길이에서 가장 덜 바꾸는 쪽).

struct Span: Hashable { var back: Int; var front: Int; var mm: Int }

enum AutoFit {
    /// 방 좌표(mm) 꼭짓점과 벽 방향·안쪽 방향
    static func geom(_ walls: [AWall], lens: [Double]? = nil) -> (P: [CGPoint], u: [CGPoint], v: [CGPoint]) {
        var x = 0.0, y = 0.0, a = 0.0
        var P = [CGPoint.zero], U: [CGPoint] = []
        for (k, w) in walls.enumerated() {
            let r = a * .pi / 180, L = lens?[k] ?? Double(w.len)
            U.append(CGPoint(x: cos(r), y: sin(r)))
            x += cos(r) * L; y += sin(r) * L; P.append(CGPoint(x: x, y: y)); a += w.turnDeg
        }
        let n = walls.count
        let poly = Array(P.prefix(n))
        let V = (0..<n).map { k -> CGPoint in
            let m = CGPoint(x: (P[k].x + P[k + 1].x) / 2, y: (P[k].y + P[k + 1].y) / 2)
            let c = CGPoint(x: -U[k].y, y: U[k].x)
            let probe = CGPoint(x: m.x + c.x * 30, y: m.y + c.y * 30)
            return inside(probe, poly) ? c : CGPoint(x: -c.x, y: -c.y)
        }
        return (P, U, V)
    }
    static func inside(_ q: CGPoint, _ P: [CGPoint]) -> Bool {
        var c = false; var j = P.count - 1
        for i in P.indices { let a = P[i], b = P[j]
            if (a.y > q.y) != (b.y > q.y), q.x < (b.x - a.x) * (q.y - a.y) / (b.y - a.y) + a.x { c.toggle() }
            j = i }
        return c
    }
    static func dot(_ a: CGPoint, _ b: CGPoint) -> Double { a.x * b.x + a.y * b.y }

    /// 원래 길이 x0에서 가장 덜 바꾸면서 닫힘 + 잰 거리 조건을 맞춘 벽 길이
    static func solve(_ walls: [AWall], _ spans: [Span]) -> [Int]? {
        let n = walls.count; guard n >= 3 else { return nil }
        let g = geom(walls), x0 = walls.map { Double(max(1, $0.len)) }
        let mx = x0.max() ?? 1
        let w = x0.map { ($0 / mx) * ($0 / mx) + 1e-4 }
        var A: [[Double]] = [g.u.map { $0.x }, g.u.map { $0.y }], b: [Double] = [0, 0]
        for s in spans {
            let nrm = g.v[s.back]; var row = Array(repeating: 0.0, count: n)
            var k = (s.back + 1) % n
            while k != s.front { row[k] = dot(g.u[k], nrm); k = (k + 1) % n }
            A.append(row); b.append(Double(s.mm))
        }
        let m = A.count
        // r = b - A x0,  M = A W A^T,  M λ = r,  x = x0 + W A^T λ
        var r = [Double](repeating: 0, count: m)
        var M = [[Double]](repeating: [Double](repeating: 0, count: m), count: m)
        for i in 0..<m {
            var s = b[i]
            for k in 0..<n { s -= A[i][k] * x0[k] }
            r[i] = s
            for j in 0..<m {
                var t = 0.0
                for k in 0..<n { t += A[i][k] * w[k] * A[j][k] }
                M[i][j] = t
            }
            M[i][i] += 1e-9
        }
        guard let lam = gauss(M, r) else { return nil }
        var x = [Double](repeating: 0, count: n)
        for k in 0..<n {
            var t = 0.0
            for i in 0..<m { t += A[i][k] * lam[i] }
            x[k] = x0[k] + w[k] * t
        }
        guard x.allSatisfy({ $0 > 50 }) else { return nil }
        return x.map { Int(($0 / 10).rounded()) * 10 }
    }
    static func gauss(_ A0: [[Double]], _ b0: [Double]) -> [Double]? {
        var A = A0, b = b0; let n = b.count
        for c in 0..<n {
            guard let p = (c..<n).max(by: { abs(A[$0][c]) < abs(A[$1][c]) }), abs(A[p][c]) > 1e-12 else { return nil }
            A.swapAt(c, p); b.swapAt(c, p)
            for r in 0..<n where r != c { let f = A[r][c] / A[c][c]; if f == 0 { continue }
                for k in c..<n { A[r][k] -= f * A[c][k] }; b[r] -= f * b[c] }
        }
        return (0..<n).map { b[$0] / A[$0][$0] }
    }

    /// 세로 벽면(세계 x,z m · 방 안쪽 법선) → 방 좌표(mm)로 옮기는 회전·이동. 맞춘 벽 수가 2 이상이고 서로 꺾여야 확정.
    struct Plane { var c: CGPoint; var n: CGPoint; var w: Double }
    struct Fit { var th: Double; var t: CGPoint; var score: Double; var used: Int
        func map(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x * cos(th) - p.y * sin(th)) * 1000 + t.x, y: (p.x * sin(th) + p.y * cos(th)) * 1000 + t.y) }
        func dir(_ d: CGPoint) -> CGPoint { CGPoint(x: d.x * cos(th) - d.y * sin(th), y: d.x * sin(th) + d.y * cos(th)) }
    }
    static func ang(_ p: CGPoint) -> Double { atan2(p.y, p.x) }
    static func adiff(_ a: Double, _ b: Double) -> Double { var d = a - b; while d > .pi { d -= 2 * .pi }; while d < -.pi { d += 2 * .pi }; return abs(d) }

    static func align(_ walls: [AWall], _ planes: [Plane]) -> Fit? {
        let g = geom(walls), n = walls.count
        guard planes.count >= 2 else { return nil }
        let xs: [Double] = g.P.map { Double($0.x) }, ys: [Double] = g.P.map { Double($0.y) }
        let spanX: Double = (xs.max() ?? 0) - (xs.min() ?? 0), spanY: Double = (ys.max() ?? 0) - (ys.min() ?? 0)
        let diag: Double = (spanX * spanX + spanY * spanY).squareRoot()
        let tol = max(150, diag * 0.05), atol = 14 * Double.pi / 180
        var best: Fit? = nil
        for (k1, p1) in planes.enumerated() { for i1 in 0..<n {
            let th = ang(g.v[i1]) - ang(p1.n)
            let R = Fit(th: th, t: .zero, score: 0, used: 0)
            for (k2, p2) in planes.enumerated() where k2 != k1 {
                let n2 = R.dir(p2.n)
                guard adiff(ang(n2), ang(g.v[i1])) > 50 * .pi / 180, adiff(ang(n2), ang(g.v[i1])) < 130 * .pi / 180 else { continue }
                for i2 in 0..<n where adiff(ang(g.v[i2]), ang(n2)) < atol {
                    // (R c1 + t - P[i1])·v1 = 0, (R c2 + t - P[i2])·v2 = 0
                    let c1 = R.map(p1.c), c2 = R.map(p2.c), v1 = g.v[i1], v2 = g.v[i2]
                    let r1 = -dot(CGPoint(x: c1.x - g.P[i1].x, y: c1.y - g.P[i1].y), v1)
                    let r2 = -dot(CGPoint(x: c2.x - g.P[i2].x, y: c2.y - g.P[i2].y), v2)
                    let det = v1.x * v2.y - v1.y * v2.x; guard abs(det) > 0.3 else { continue }
                    let t = CGPoint(x: (r1 * v2.y - v1.y * r2) / det, y: (v1.x * r2 - r1 * v2.x) / det)
                    var f = Fit(th: th, t: t, score: 0, used: 0)
                    for p in planes {
                        let c = f.map(p.c), nn = f.dir(p.n)
                        var ok = false
                        for i in 0..<n where adiff(ang(g.v[i]), ang(nn)) < atol {
                            let d = abs(dot(CGPoint(x: c.x - g.P[i].x, y: c.y - g.P[i].y), g.v[i]))
                            let s = dot(CGPoint(x: c.x - g.P[i].x, y: c.y - g.P[i].y), g.u[i]), L = Double(walls[i].len)
                            if d < tol && s > -400 && s < L + 400 { ok = true; break }
                        }
                        if ok { f.score += p.w; f.used += 1 } else { f.score -= p.w * 0.5 }
                    }
                    if f.used >= 2, f.score > (best?.score ?? 0) { best = f }
                }
            }
        } }
        return best
    }

    /// 방 좌표에서 점 q, 방향 d로 쏜 반직선이 처음 만나는 벽(번호, 거리)
    static func cast(_ walls: [AWall], _ q: CGPoint, _ d: CGPoint) -> (Int, Double)? {
        let g = geom(walls); var best: (Int, Double)? = nil
        for i in 0..<walls.count {
            let a = g.P[i], e = CGPoint(x: g.P[i + 1].x - a.x, y: g.P[i + 1].y - a.y)
            let den = d.x * e.y - d.y * e.x; guard abs(den) > 1e-9 else { continue }
            let w = CGPoint(x: a.x - q.x, y: a.y - q.y)
            let t = (w.x * e.y - w.y * e.x) / den, s = (w.x * d.y - w.y * d.x) / den
            if t > 1, s >= -0.02, s <= 1.02, Double(t) < (best?.1 ?? .infinity) { best = (i, Double(t)) }
        }
        return best
    }
}

// MARK: - 카메라 쪽

final class AutoController: NSObject, ObservableObject, ARSessionDelegate {
    let view = ARSCNView(frame: .zero)
    var walls: [AWall] = []
    @Published var fit: AutoFit.Fit?
    @Published var planeCount = 0
    @Published var pos: CGPoint?        // 방 좌표 mm
    @Published var dir: CGPoint?        // 방 좌표 단위 방향
    @Published var target: (back: Int, front: Int, now: Int)?
    @Published var aimMsg = "주변 벽을 천천히 비춰 주세요"
    private var planes: [UUID: AutoFit.Plane] = [:]
    private var last = Date.distantPast

    func start() {
        let c = ARWorldTrackingConfiguration(); c.planeDetection = [.vertical]
        view.session.delegate = self
        view.session.run(c)
    }
    func stop() { view.session.pause() }

    func session(_ s: ARSession, didAdd anchors: [ARAnchor]) { upd(anchors, s) }
    func session(_ s: ARSession, didUpdate anchors: [ARAnchor]) { upd(anchors, s) }
    private func upd(_ anchors: [ARAnchor], _ s: ARSession) {
        guard let cam = s.currentFrame?.camera.transform.columns.3 else { return }
        for case let a as ARPlaneAnchor in anchors where a.alignment == .vertical {
            let T = a.transform, c = T * simd_float4(a.center.x, a.center.y, a.center.z, 1)
            var nrm = CGPoint(x: Double(T.columns.1.x), y: Double(T.columns.1.z))
            let l = hypot(nrm.x, nrm.y); guard l > 0.5 else { continue }
            nrm = CGPoint(x: nrm.x / l, y: nrm.y / l)
            if Double(cam.x - c.x) * nrm.x + Double(cam.z - c.z) * nrm.y < 0 { nrm = CGPoint(x: -nrm.x, y: -nrm.y) }  // 방 안쪽(폰 쪽)으로
            let w = Double(max(a.planeExtent.width, 0.1))
            guard w > 0.4 else { continue }
            planes[a.identifier] = AutoFit.Plane(c: CGPoint(x: Double(c.x), y: Double(c.z)), n: nrm, w: w)
        }
        DispatchQueue.main.async { self.planeCount = self.planes.count }
        if Date().timeIntervalSince(last) > 0.7 {
            last = Date()
            let f = AutoFit.align(walls, Array(planes.values))
            DispatchQueue.main.async { if let f { self.fit = f } }
        }
    }
    func session(_ s: ARSession, didUpdate frame: ARFrame) {
        guard let f = fit else { DispatchQueue.main.async { self.aimMsg = self.planes.count < 2 ? "주변 벽을 천천히 비춰 주세요 (모서리 양쪽 벽이 보이게)" : "도면과 맞추는 중… 다른 벽도 비춰 주세요" }; return }
        let T = frame.camera.transform, p = T.columns.3, z = T.columns.2
        let q = f.map(CGPoint(x: Double(p.x), y: Double(p.z)))
        var d = f.dir(CGPoint(x: Double(-z.x), y: Double(-z.z)))
        let l = hypot(d.x, d.y); guard l > 0.3 else { return }
        d = CGPoint(x: d.x / l, y: d.y / l)
        var tg: (Int, Int, Int)? = nil, msg = "폰을 측정기와 같은 방향으로 벽에 겨누세요"
        if let fr = AutoFit.cast(walls, q, d), let bk = AutoFit.cast(walls, q, CGPoint(x: -d.x, y: -d.y)) {
            let g = AutoFit.geom(walls)
            if AutoFit.adiff(AutoFit.ang(g.v[fr.0]), AutoFit.ang(g.v[bk.0]) + .pi) < 8 * .pi / 180 {
                let now = abs(AutoFit.dot(CGPoint(x: g.P[fr.0].x - g.P[bk.0].x, y: g.P[fr.0].y - g.P[bk.0].y), g.v[bk.0]))
                tg = (bk.0, fr.0, Int(now.rounded())); msg = "뒤 \(bk.0 + 1)번 벽 → 앞 \(fr.0 + 1)번 벽"
            } else { msg = "마주 보는 벽이 아닙니다. 벽에 똑바로 겨누세요" }
        }
        DispatchQueue.main.async { self.pos = q; self.dir = d; self.target = tg.map { (back: $0.0, front: $0.1, now: $0.2) }; self.aimMsg = msg }
    }
}

struct AutoRep: UIViewRepresentable {
    let c: AutoController
    func makeUIView(context: Context) -> ARSCNView { c.view }
    func updateUIView(_ v: ARSCNView, context: Context) {}
}

struct AutoMeasureScreen: View {
    let roomId: String
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @StateObject private var ac = AutoController()
    @ObservedObject var laser = LaserLink.shared
    @State private var base: [AWall] = []
    @State private var spans: [Span] = []
    @State private var lens: [Int]? = nil
    @State private var manual = ""
    @State private var msg: String?
    @FocusState private var focus: Bool

    var body: some View {
        ZStack {
            AutoRep(c: ac).ignoresSafeArea()
            Image(systemName: "plus").font(.system(size: 34, weight: .light)).foregroundStyle(ac.target != nil ? .yellow : .white)
            VStack(spacing: 8) {
                HStack {
                    Button("닫기") { ac.stop(); dismiss() }.padding(.horizontal, 14).padding(.vertical, 9).background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                    Button("저장") { save() }.fontWeight(.bold).padding(.horizontal, 16).padding(.vertical, 9)
                        .background(spans.isEmpty ? Color.gray : Color.white, in: Capsule()).foregroundStyle(.black).disabled(spans.isEmpty)
                }.padding(.horizontal, 14)
                Text(ac.fit == nil ? ac.aimMsg : ac.aimMsg).font(.footnote.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 7).background(.black.opacity(0.6), in: Capsule())
                Spacer()
                plan.frame(height: 210).background(.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 16)).padding(.horizontal, 14)
                if let m = msg { Text(m).font(.caption).foregroundStyle(.white).padding(6).background(.black.opacity(0.6), in: Capsule()) }
                HStack(spacing: 8) {
                    if let t = ac.target {
                        Text("지금 도면 \(mm(t.now))").font(.subheadline.weight(.semibold))
                    } else { Text("겨눈 벽 없음").font(.subheadline).foregroundStyle(.secondary) }
                    TextField("줄자 값", text: $manual).keyboardType(.numberPad).focused($focus).frame(width: 90)
                        .padding(8).background(Color(white: 0.95), in: RoundedRectangle(cornerRadius: 10))
                    Button("넣기") { if let v = Int(manual.filter(\.isNumber)) { apply(v); manual = ""; focus = false } }.buttonStyle(.bordered)
                    if laser.connected { Button("측정") { laser.trigger() }.buttonStyle(.borderedProminent) }
                }
                .padding(10).background(.white, in: RoundedRectangle(cornerRadius: 14)).padding(.horizontal, 14).padding(.bottom, 8)
            }
        }
        .onAppear {
            if let r = store.site.rooms.first(where: { $0.id == roomId }) { base = r.walls; ac.walls = r.walls }
            ac.start()
        }
        .onDisappear { ac.stop() }
        .onChange(of: laser.seq) { _, _ in if let v = laser.lastMM { apply(v) } }
    }

    func apply(_ v: Int) {
        guard let t = ac.target else { msg = "먼저 마주 보는 벽에 겨누세요"; return }
        spans.removeAll { ($0.back == t.back && $0.front == t.front) || ($0.back == t.front && $0.front == t.back) }
        spans.append(Span(back: t.back, front: t.front, mm: v))
        guard let L = AutoFit.solve(base, spans) else { spans.removeLast(); msg = "그 값으로는 방이 맞지 않습니다. 다시 재 보세요"; return }
        lens = L
        var w = base; for k in w.indices { w[k].len = L[k] }; ac.walls = w
        msg = "\(t.back + 1)↔\(t.front + 1) \(mm(v)) 반영 · 잰 거리 \(spans.count)개로 방 전체를 다시 맞췄습니다"
    }

    func save() {
        guard let L = lens, let i = store.site.rooms.firstIndex(where: { $0.id == roomId }) else { return }
        var r = store.site.rooms[i]
        for k in r.walls.indices where k < L.count {
            r.walls[k].len = L[k]
            r.walls[k].ops = r.walls[k].ops.map { var o = $0; o.w = min(o.w, L[k]); o.off = max(0, min(o.off, L[k] - o.w)); return o }
        }
        store.site.rooms[i] = r
        ac.stop(); dismiss()
    }

    var plan: some View {
        Canvas { ctx, size in
            let walls = ac.walls; guard walls.count >= 3 else { return }
            let g = AutoFit.geom(walls), P = Array(g.P.prefix(walls.count))
            let xs = P.map(\.x), ys = P.map(\.y), pad = 30.0
            let k = min((size.width - pad * 2) / max(1, xs.max()! - xs.min()!), (size.height - pad * 2) / max(1, ys.max()! - ys.min()!))
            let ox = (size.width - (xs.max()! - xs.min()!) * k) / 2 - xs.min()! * k, oy = (size.height - (ys.max()! - ys.min()!) * k) / 2 - ys.min()! * k
            func S(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * k + ox, y: p.y * k + oy) }
            let acc = Color(red: 0.25, green: 0.32, blue: 0.28)
            let measured = Set(spans.flatMap { [$0.back, $0.front] })
            for i in 0..<walls.count {
                var p = Path(); p.move(to: S(g.P[i])); p.addLine(to: S(g.P[i + 1]))
                let on = ac.target.map { $0.back == i || $0.front == i } ?? false
                ctx.stroke(p, with: .color(on ? .orange : measured.contains(i) ? acc : .black), lineWidth: on ? 5 : 3)
                let m = S(CGPoint(x: (g.P[i].x + g.P[i + 1].x) / 2, y: (g.P[i].y + g.P[i + 1].y) / 2))
                let changed = lens != nil && lens![i] != base[i].len
                ctx.draw(Text("\(i + 1) \(mm(walls[i].len))").font(.caption2.weight(changed ? .bold : .regular)).foregroundColor(changed ? acc : .gray),
                         at: CGPoint(x: m.x - g.v[i].x * 14, y: m.y - g.v[i].y * 14))
            }
            if let q = ac.pos, let d = ac.dir {
                let s = S(q)
                ctx.fill(Path(ellipseIn: CGRect(x: s.x - 6, y: s.y - 6, width: 12, height: 12)), with: .color(.blue))
                var ray = Path(); ray.move(to: s); ray.addLine(to: CGPoint(x: s.x + d.x * 40, y: s.y + d.y * 40))
                ctx.stroke(ray, with: .color(.blue), lineWidth: 2)
            } else {
                ctx.draw(Text(ac.planeCount < 2 ? "벽 \(ac.planeCount)개 찾음" : "맞추는 중").font(.caption).foregroundColor(.gray), at: CGPoint(x: size.width / 2, y: 14))
            }
        }
    }
}
