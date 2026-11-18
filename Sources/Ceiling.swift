import SwiftUI

/// 몰딩·걸레받이 → 도배 높이 자동, 천장(그냥/우물) 작도, 조명·실링팬 위치. 웹앱·도배계산기와 같은 값.
struct CeilingScreen: View {
    let roomId: String
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State private var r: ScanRoom? = nil
    @State private var sel: (Character, Int)? = nil     // ("w"|"m", 순번)
    @State private var drag: (mode: String, start: CGPoint, orig: CGRect)? = nil
    @State private var view = CGSize.zero

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                GeometryReader { geo in
                    Canvas { ctx, size in draw(ctx, size) }
                        .background(Color.white)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { v in onDrag(v, geo.size) }
                            .onEnded { _ in drag = nil })
                        .onAppear { view = geo.size }
                }
                if r != nil { controls }
            }
            .background(Color(white: 0.96))
            .navigationTitle("\(r?.name ?? "") 천장").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("닫기") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button("저장") { save(); dismiss() }.fontWeight(.semibold) }
            }
            .onAppear {
                guard r == nil, var x = store.site.rooms.first(where: { $0.id == roomId }) else { return }
                if x.mold == nil { x.mold = AMold(k: (x.moldType ?? "none") == "none" ? "none" : "flat", h: (x.moldH ?? 0) > 0 ? x.moldH! : 40) }
                if x.bb == nil { x.bb = x.baseH ?? 80 }
                if x.bbT == nil { x.bbT = 9 }
                if x.ceilT == nil { x.ceilT = "flat" }
                if x.wells == nil { x.wells = [] }
                if x.marks == nil { x.marks = [] }
                r = x
            }
        }
    }

    // MARK: 화면 ↔ 방(네모 왼쪽 위 기준 mm)
    func xf(_ size: CGSize) -> (k: Double, ox: Double, oy: Double, B: CGRect) {
        let B = r?.box ?? .zero, pad = min(60.0, size.width * 0.12)
        let k = min((size.width - pad * 2) / max(1, B.width), (size.height - pad * 2) / max(1, B.height))
        return (k, (size.width - B.width * k) / 2, (size.height - B.height * k) / 2, B)
    }
    func toS(_ p: CGPoint, _ size: CGSize) -> CGPoint { let t = xf(size); return CGPoint(x: t.ox + p.x * t.k, y: t.oy + p.y * t.k) }
    func toR(_ p: CGPoint, _ size: CGSize) -> CGPoint { let t = xf(size); return CGPoint(x: (p.x - t.ox) / t.k, y: (p.y - t.oy) / t.k) }

    func onDrag(_ v: DragGesture.Value, _ size: CGSize) {
        guard var x = r else { return }
        if drag == nil {
            let p = v.startLocation; sel = nil
            for (i, m) in (x.marks ?? []).enumerated().reversed() {
                let s = toS(CGPoint(x: m.x, y: m.y), size)
                if hypot(s.x - p.x, s.y - p.y) < 22 { sel = ("m", i); drag = ("move", toR(p, size), CGRect(x: m.x, y: m.y, width: 0, height: 0)); break }
            }
            if sel == nil, x.ceilT == "well" {
                for (i, w) in (x.wells ?? []).enumerated().reversed() {
                    let a = toS(CGPoint(x: w.x, y: w.y), size), b = toS(CGPoint(x: w.x + w.a, y: w.y + w.b), size)
                    let o = CGRect(x: w.x, y: w.y, width: w.a, height: w.b)
                    if hypot(b.x - p.x, b.y - p.y) < 24 { sel = ("w", i); drag = ("size", toR(p, size), o); break }
                    if p.x > a.x, p.x < b.x, p.y > a.y, p.y < b.y { sel = ("w", i); drag = ("move", toR(p, size), o); break }
                }
            }
            return
        }
        guard let d = drag, let s = sel else { return }
        let q = toR(v.location, size), dx = q.x - d.start.x, dy = q.y - d.start.y
        func sn(_ v: Double) -> Int { Int((v / 10).rounded()) * 10 }
        if s.0 == "m" { x.marks![s.1].x = sn(d.orig.minX + dx); x.marks![s.1].y = sn(d.orig.minY + dy) }
        else if d.mode == "move" { x.wells![s.1].x = sn(d.orig.minX + dx); x.wells![s.1].y = sn(d.orig.minY + dy) }
        else { x.wells![s.1].a = max(300, sn(d.orig.width + dx)); x.wells![s.1].b = max(300, sn(d.orig.height + dy)) }
        r = x
    }

    func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        guard let x = r, x.walls.count >= 3 else { return }
        let acc = Color(red: 0.25, green: 0.32, blue: 0.28), B = x.box
        let pts = x.localPoints().prefix(x.walls.count).map { toS(CGPoint(x: $0.x - B.minX, y: $0.y - B.minY), size) }
        var poly = Path(); poly.addLines(Array(pts)); poly.closeSubpath()
        ctx.fill(poly, with: .color(Color(red: 0.90, green: 0.93, blue: 0.91)))
        ctx.stroke(poly, with: .color(.black), lineWidth: 4)
        // 벽 길이
        let n = pts.count
        var area = 0.0; for i in 0..<n { let a = pts[i], b = pts[(i + 1) % n]; area += a.x * b.y - b.x * a.y }
        let side: Double = area >= 0 ? 1 : -1
        for i in 0..<n {
            let a = pts[i], b = pts[(i + 1) % n], L = max(1, hypot(b.x - a.x, b.y - a.y))
            guard L > 40 else { continue }
            let nx = (b.y - a.y) / L * side, ny = -(b.x - a.x) / L * side
            ctx.draw(Text(mm(x.walls[i].len)).font(.caption2).foregroundColor(.gray), at: CGPoint(x: (a.x + b.x) / 2 + nx * 22, y: (a.y + b.y) / 2 + ny * 14))
        }
        if x.ceilT == "well" {
            for (i, w) in (x.wells ?? []).enumerated() {
                let a = toS(CGPoint(x: w.x, y: w.y), size), b = toS(CGPoint(x: w.x + w.a, y: w.y + w.b), size)
                let on = sel?.0 == "w" && sel?.1 == i, c: Color = on ? acc : .black
                let rc = CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
                ctx.stroke(Path(rc), with: .color(c), lineWidth: on ? 2.5 : 1.6)
                ctx.stroke(Path(rc.insetBy(dx: 6, dy: 6)), with: .color(c), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                ctx.draw(Text("우물 \(mm(w.a))×\(mm(w.b)) 깊이 \(mm(w.d))").font(.caption.weight(.semibold)).foregroundColor(c), at: CGPoint(x: rc.midX, y: rc.minY + 18))
                let h = CGRect(x: b.x - 7, y: b.y - 7, width: 14, height: 14)
                ctx.fill(Path(h), with: .color(on ? acc : .white)); ctx.stroke(Path(h), with: .color(c), lineWidth: 1.5)
            }
        }
        for (i, m) in (x.marks ?? []).enumerated() {
            let s = toS(CGPoint(x: m.x, y: m.y), size), on = sel?.0 == "m" && sel?.1 == i, c: Color = on ? acc : .black
            let rr: Double = m.k == "fan" ? 15 : 11
            let circ = Path(ellipseIn: CGRect(x: s.x - rr, y: s.y - rr, width: rr * 2, height: rr * 2))
            ctx.fill(circ, with: .color(.white)); ctx.stroke(circ, with: .color(c), lineWidth: on ? 2.5 : 1.8)
            var p = Path()
            if m.k == "fan" {
                for k in 0..<3 { let an = Double(k) * 2.094 + 0.3; p.move(to: s); p.addLine(to: CGPoint(x: s.x + cos(an) * 13, y: s.y + sin(an) * 13)) }
                ctx.stroke(p, with: .color(c), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            } else {
                p.move(to: CGPoint(x: s.x - 8, y: s.y - 8)); p.addLine(to: CGPoint(x: s.x + 8, y: s.y + 8))
                p.move(to: CGPoint(x: s.x + 8, y: s.y - 8)); p.addLine(to: CGPoint(x: s.x - 8, y: s.y + 8))
                ctx.stroke(p, with: .color(c), lineWidth: 1.8)
            }
        }
        // 고른 것: 왼쪽·위에서 거리
        if let s = sel {
            let c: CGPoint = s.0 == "m" ? CGPoint(x: x.marks![s.1].x, y: x.marks![s.1].y) : CGPoint(x: x.wells![s.1].x, y: x.wells![s.1].y)
            let p = toS(c, size), l = toS(CGPoint(x: 0, y: c.y), size), u = toS(CGPoint(x: c.x, y: 0), size)
            var d = Path(); d.move(to: l); d.addLine(to: p); d.move(to: u); d.addLine(to: p)
            ctx.stroke(d, with: .color(acc), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            func lab(_ t: String, _ at: CGPoint) {
                let tx = ctx.resolve(Text(t).font(.caption.weight(.bold)).foregroundColor(.white)); let sz = tx.measure(in: CGSize(width: 200, height: 30))
                let box = CGRect(x: at.x - sz.width / 2 - 6, y: at.y - 10, width: sz.width + 12, height: 20)
                ctx.fill(Path(roundedRect: box, cornerRadius: 10), with: .color(acc)); ctx.draw(tx, at: at)
            }
            lab(mm(Int(c.x)), CGPoint(x: (l.x + p.x) / 2, y: p.y - 14))
            lab(mm(Int(c.y)), CGPoint(x: p.x + (s.0 == "w" ? -30 : 30), y: (u.y + p.y) / 2))
        }
    }

    // MARK: 아래 조작
    func num(_ title: String, _ v: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            TextField("0", value: v, format: .number).keyboardType(.numberPad)
                .padding(8).background(Color.white, in: RoundedRectangle(cornerRadius: 10))
        }
    }
    func chip(_ t: String, _ on: Bool, _ act: @escaping () -> Void) -> some View {
        Button(t, action: act).font(.subheadline).padding(.horizontal, 12).padding(.vertical, 7)
            .background(on ? Color.black : Color.white, in: Capsule()).foregroundStyle(on ? .white : .black)
    }
    func bind<T>(_ kp: WritableKeyPath<ScanRoom, T>, _ def: T) -> Binding<T> {
        Binding(get: { r?[keyPath: kp] ?? def }, set: { v in r?[keyPath: kp] = v })
    }

    var controls: some View {
        let x = r!, m = x.mold ?? AMold()
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text("몰딩").font(.caption).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                    chip("없음", m.k == "none") { r?.mold?.k = "none" }
                    chip("평몰딩", m.k == "flat") { r?.mold?.k = "flat" }
                    chip("각몰딩", m.k == "crown") { r?.mold?.k = "crown" }
                }
                if m.k == "flat" { HStack { num("벽에 닿는 높이", bind(\.mold!.h, 40)) } }
                if m.k == "crown" {
                    HStack(alignment: .bottom) {
                        num("몰딩 폭", bind(\.mold!.w, 60)); num("각도(°)", bind(\.mold!.a, 45))
                        Text("벽 \(x.moldDrop) · 천장 \(x.moldProj)").font(.caption).foregroundStyle(.secondary).padding(.bottom, 10)
                    }
                }
                HStack { num("걸레받이 높이", bind(\.bb!, 80)); num("걸레받이 두께", bind(\.bbT!, 9)); num("천장고", bind(\.ceil, 2300)) }
                Text("도배 높이 \(mm(paper(x)))mm 자동 계산").font(.subheadline.weight(.semibold))
                HStack(spacing: 6) {
                    Text("천장").font(.caption).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                    chip("그냥 천장", x.ceilT != "well") { r?.ceilT = "flat"; sel = nil }
                    chip("우물천장", x.ceilT == "well") { r?.ceilT = "well"; if (r?.wells ?? []).isEmpty { add("well") } }
                    if x.ceilT == "well" { Button("+ 우물") { add("well") }.buttonStyle(.bordered) }
                }
                HStack(spacing: 6) {
                    Text("달기").font(.caption).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                    Button("+ 조명") { add("light") }.buttonStyle(.bordered)
                    Button("+ 실링팬") { add("fan") }.buttonStyle(.bordered)
                    Text("조명 \((x.marks ?? []).filter { $0.k == "light" }.count) · 실링팬 \((x.marks ?? []).filter { $0.k == "fan" }.count)").font(.caption).foregroundStyle(.secondary)
                }
                if let s = sel {
                    HStack(alignment: .bottom, spacing: 6) {
                        if s.0 == "m" {
                            num("왼쪽에서", bind(\.marks![s.1].x, 0)); num("위에서", bind(\.marks![s.1].y, 0))
                        } else {
                            num("왼쪽에서", bind(\.wells![s.1].x, 0)); num("위에서", bind(\.wells![s.1].y, 0))
                            num("가로", bind(\.wells![s.1].a, 0)); num("세로", bind(\.wells![s.1].b, 0)); num("깊이", bind(\.wells![s.1].d, 120))
                        }
                        Button("빼기") { if s.0 == "m" { r?.marks?.remove(at: s.1) } else { r?.wells?.remove(at: s.1) }; sel = nil }
                            .buttonStyle(.bordered).tint(.red)
                    }
                }
                Text("조명·우물을 눌러 고르고 끌어서 옮기세요. 우물은 오른쪽 아래 네모로 크기를 바꿉니다. 거리는 방을 감싸는 네모의 왼쪽·위에서 잽니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(14)
        }
        .frame(maxHeight: 360)
    }

    func paper(_ x: ScanRoom) -> Int { max(300, x.ceil - (x.bb ?? 0) - x.moldDrop) }

    func add(_ k: String) {
        guard var x = r else { return }
        let B = x.box
        if k == "well" {
            let ins = max(300, Int((min(B.width, B.height) * 0.12 / 10).rounded()) * 10)
            x.wells = (x.wells ?? []) + [AWell(x: ins, y: ins, a: max(300, Int(B.width) - ins * 2), b: max(300, Int(B.height) - ins * 2), d: 120)]
            sel = ("w", x.wells!.count - 1)
        } else {
            let w = x.ceilT == "well" ? x.wells?.first : nil
            let cx = w.map { Double($0.x) + Double($0.a) / 2 } ?? B.width / 2, cy = w.map { Double($0.y) + Double($0.b) / 2 } ?? B.height / 2
            let n = (x.marks ?? []).count, off = (n % 2 == 1 ? 1 : -1) * ((n + 1) / 2) * 500
            x.marks = (x.marks ?? []) + [AMark(k: k, x: Int((cx / 10).rounded()) * 10 + off, y: Int((cy / 10).rounded()) * 10)]
            sel = ("m", x.marks!.count - 1)
        }
        r = x
    }

    func save() {
        guard var x = r, let i = store.site.rooms.firstIndex(where: { $0.id == roomId }) else { return }
        // 예전 값도 같이 맞춰 견적·내보내기에 그대로 쓰이게
        x.moldType = (x.mold?.k ?? "none") == "none" ? "none" : "flat"
        x.moldH = x.moldDrop
        x.baseH = x.bb ?? 0
        if !(1500...6000).contains(x.ceil) { x.ceil = store.site.rooms[i].ceil }
        store.site.rooms[i] = x
    }
}
