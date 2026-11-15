import SwiftUI
import UIKit

@MainActor
enum Exporter {
    static func tmp(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(name.replacingOccurrences(of: "/", with: "_"))
    }
    static func siteName(_ s: Site) -> String { s.name.isEmpty ? "라이다 스캔 현장" : s.name }

    static func renderPDF<V: View>(_ view: V, to url: URL) -> URL? {
        let r = ImageRenderer(content: view)
        var ok = false
        r.render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard let c = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
            c.beginPDFPage(nil); draw(c); c.endPDFPage(); c.closePDF()
            ok = true
        }
        return ok ? url : nil
    }

    // MARK: 2D 도면 PDF (A3 가로 비율, 평면도 + 천장도 + 면적표)
    static func planPDF(_ site: Site) -> URL? {
        let rooms = site.placedRooms
        let view = VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ANRAK").font(.system(size: 9, weight: .semibold)).tracking(2).foregroundColor(.gray)
                    Text(siteName(site)).font(.system(size: 20, weight: .bold))
                    if !site.addr.isEmpty { Text(site.addr).font(.system(size: 10)).foregroundColor(.gray) }
                }
                Spacer()
                Text("치수는 벽 안쪽 기준 · 단위 mm · \(dateStr())").font(.system(size: 9)).foregroundColor(.gray)
            }
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("평면도").font(.system(size: 12, weight: .semibold))
                    PlanCanvas(rooms: rooms, ceiling: false, fontScale: 1.0).frame(width: 540, height: 430)
                        .border(Color(white: 0.85))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("천장도").font(.system(size: 12, weight: .semibold))
                    PlanCanvas(rooms: rooms, ceiling: true, fontScale: 1.0).frame(width: 540, height: 430)
                        .border(Color(white: 0.85))
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                tableRow(["방", "바닥 ㎡", "평", "천장 높이", "천장 가로×세로", "둘레 m", "벽 도배 ㎡", "몰딩", "걸레받이", "문", "창"], bold: true)
                ForEach(rooms) { r in
                    let (cw, cd) = r.ceilingBox
                    let ops = r.walls.flatMap { $0.ops }
                    tableRow([r.name, String(format: "%.1f", r.area), String(format: "%.1f", r.area / Calc.py), mm(r.ceil), "\(mm(cw))×\(mm(cd))",
                              String(format: "%.1f", Double(r.perimeter) / 1000), String(format: "%.1f", r.wallArea),
                              moldName(r.moldType) + ((r.moldType ?? "none") == "none" ? "" : " \(r.moldH ?? 0)"),
                              (r.baseH ?? 0) == 0 ? "없음" : "\(r.baseH ?? 0)",
                              "\(ops.filter { $0.kind == "door" }.count)", "\(ops.filter { $0.kind == "window" }.count)"], bold: false)
                }
            }
        }
        .padding(28).frame(width: 1150).background(Color.white).environment(\.colorScheme, .light)
        return renderPDF(view, to: tmp("\(siteName(site))_도면.pdf"))
    }

    static func tableRow(_ cells: [String], bold: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { i, c in
                Text(c).font(.system(size: 9, weight: bold ? .semibold : .regular))
                    .frame(width: i == 0 ? 110 : (i == 4 ? 120 : 86), alignment: i == 0 ? .leading : .trailing)
            }
        }
        .padding(.vertical, 3)
        .overlay(alignment: .bottom) { Rectangle().fill(Color(white: bold ? 0.3 : 0.88)).frame(height: 0.5) }
    }

    static func dateStr() -> String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date()) }

    // MARK: 견적서 PDF
    static func estimatePDF(_ site: Site, lines: [EstLine], total t: Calc.Total) -> URL? {
        let roomName = Dictionary(uniqueKeysWithValues: site.rooms.map { ($0.id, $0.name) })
        func line(_ a: String, _ b: String, _ q: String, _ u: String, _ m: String, _ l: String, _ s: String, bold: Bool = false) -> some View {
            HStack(spacing: 0) {
                Text(a).frame(width: 70, alignment: .leading)
                Text(b).frame(width: 190, alignment: .leading)
                Text(q).frame(width: 48, alignment: .trailing)
                Text(u).frame(width: 34, alignment: .center)
                Text(m).frame(width: 70, alignment: .trailing)
                Text(l).frame(width: 70, alignment: .trailing)
                Text(s).frame(width: 78, alignment: .trailing)
            }
            .font(.system(size: 9, weight: bold ? .semibold : .regular)).padding(.vertical, 3)
            .overlay(alignment: .bottom) { Rectangle().fill(Color(white: bold ? 0.3 : 0.9)).frame(height: 0.5) }
        }
        let view = VStack(alignment: .leading, spacing: 10) {
            Text("ANRAK  INTERIOR · SMART HOME").font(.system(size: 9, weight: .semibold)).tracking(2).foregroundColor(.gray)
            Text("견 적 서").font(.system(size: 24, weight: .bold))
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("현장: \(siteName(site))").font(.system(size: 11))
                    if !site.addr.isEmpty { Text("주소: \(site.addr)").font(.system(size: 11)) }
                    Text("견적일: \(dateStr())").font(.system(size: 11))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("합계 (부가세 \(site.vat ? "포함" : "별도"))").font(.system(size: 10)).foregroundColor(.gray)
                    Text("\(won(t.sum))원").font(.system(size: 20, weight: .bold))
                }
            }
            line("구분", "항목", "수량", "단위", "자재 단가", "시공 단가", "금액", bold: true)
            ForEach(site.rooms) { r in
                let ls = lines.filter { $0.room == r.id }
                if !ls.isEmpty {
                    Text("\(r.name)  ·  \(String(format: "%.1f", r.area))㎡ (\(String(format: "%.1f", r.area / Calc.py))평) · 천장 높이 \(mm(r.ceil))")
                        .font(.system(size: 10, weight: .semibold)).padding(.top, 6)
                    ForEach(ls) { l in line(l.cat, l.name, qtyStr(l.qty), l.unit, won(l.mat), won(l.labor), won(l.sum)) }
                    line("", "소계", "", "", "", "", won(ls.reduce(0) { $0 + $1.sum }), bold: true)
                }
            }
            if !site.extras.isEmpty {
                Text("추가 공사").font(.system(size: 10, weight: .semibold)).padding(.top, 6)
                ForEach(site.extras) { e in
                    line(e.cat, e.name, qtyStr(e.qty), e.unit, won(e.mat), won(e.labor), won(Int(e.qty * Double(e.mat + e.labor))))
                }
            }
            VStack(alignment: .trailing, spacing: 3) {
                sumRow("자재비", t.mat); sumRow("시공비", t.labor)
                sumRow("이윤·관리비 \(Int(site.marginPct))%", t.margin)
                if site.vat { sumRow("부가세 10%", t.vat) }
                HStack { Spacer(); Text("합계").font(.system(size: 12, weight: .bold)); Text("\(won(t.sum))원").font(.system(size: 14, weight: .bold)).frame(width: 130, alignment: .trailing) }
            }
            .padding(.top, 8)
            Text("· 수량은 라이다 실측 치수로 계산한 값이며 현장 여건에 따라 달라질 수 있습니다.\n· 본 견적은 견적일로부터 30일간 유효합니다.")
                .font(.system(size: 8.5)).foregroundColor(.gray).padding(.top, 8)
            let _ = roomName
        }
        .padding(34).frame(width: 628, alignment: .leading).background(Color.white).environment(\.colorScheme, .light)
        return renderPDF(view, to: tmp("\(siteName(site))_견적서.pdf"))
    }
    static func sumRow(_ k: String, _ v: Int) -> some View {
        HStack { Spacer(); Text(k).font(.system(size: 10)); Text("\(won(v))원").font(.system(size: 10)).frame(width: 130, alignment: .trailing) }
    }

    // MARK: 캐드 DXF (R12 ASCII, 단위 mm, Y 위쪽)
    static func dxf(_ site: Site) -> URL? {
        var s = "0\nSECTION\n2\nENTITIES\n"
        func esc(_ t: String) -> String {
            var o = ""
            for u in t.unicodeScalars { o += u.value < 128 ? String(u) : String(format: "\\U+%04X", u.value) }
            return o
        }
        func line(_ a: CGPoint, _ b: CGPoint, _ layer: String) {
            s += "0\nLINE\n8\n\(layer)\n10\n\(f(a.x))\n20\n\(f(-a.y))\n11\n\(f(b.x))\n21\n\(f(-b.y))\n"
        }
        func text(_ p: CGPoint, _ t: String, _ h: Double, _ layer: String, rot: Double = 0) {
            s += "0\nTEXT\n8\n\(layer)\n10\n\(f(p.x))\n20\n\(f(-p.y))\n40\n\(f(h))\n1\n\(esc(t))\n50\n\(f(rot))\n72\n1\n11\n\(f(p.x))\n21\n\(f(-p.y))\n"
        }
        func f(_ v: Double) -> String { String(format: "%.1f", v) }
        for r in site.placedRooms {
            let lp = r.localPoints(), n = r.walls.count
            guard n >= 3 else { continue }
            let pp = lp.map { r.toPlan($0) }
            let cx = pp.prefix(n).map { $0.x }.reduce(0, +) / Double(n), cy = pp.prefix(n).map { $0.y }.reduce(0, +) / Double(n)
            for i in 0..<n {
                line(pp[i], pp[i + 1 == n ? 0 : i + 1], "WALL")
                let a = pp[i], b = pp[i + 1]
                let m = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                let dx = cx - m.x, dy = cy - m.y, d = max(hypot(dx, dy), 1)
                var ang = atan2(-(b.y - a.y), b.x - a.x) * 180 / .pi
                if ang > 90 { ang -= 180 }; if ang <= -90 { ang += 180 }
                text(CGPoint(x: m.x + dx / d * 150, y: m.y + dy / d * 150), mm(r.walls[i].len), 80, "DIM", rot: ang)
                let L = Double(max(r.walls[i].len, 1))
                for op in r.walls[i].ops {
                    let t0 = Double(op.off) / L, t1 = Double(op.off + op.w) / L
                    let la = lp[i], lb = lp[i + 1]
                    let p0 = r.toPlan(CGPoint(x: la.x + (lb.x - la.x) * t0, y: la.y + (lb.y - la.y) * t0))
                    let p1 = r.toPlan(CGPoint(x: la.x + (lb.x - la.x) * t1, y: la.y + (lb.y - la.y) * t1))
                    // 벽 바깥쪽으로 100 띄운 선으로 문·창 표시
                    let ox = -dx / d * 100, oy = -dy / d * 100
                    let q0 = CGPoint(x: p0.x + ox, y: p0.y + oy), q1 = CGPoint(x: p1.x + ox, y: p1.y + oy)
                    let layer = op.kind == "door" ? "DOOR" : "WINDOW"
                    line(p0, q0, layer); line(q0, q1, layer); line(q1, p1, layer)
                }
            }
            for fx in r.fixtures ?? [] {
                let c = r.toPlan(CGPoint(x: fx.x, y: fx.y))
                s += "0\nCIRCLE\n8\nFIXTURE\n10\n\(f(c.x))\n20\n\(f(-c.y))\n40\n\(fx.kind == "aircon" ? "300.0" : "100.0")\n"
                text(CGPoint(x: c.x, y: c.y + 220), fixtureName(fx.kind), 60, "FIXTURE")
            }
            text(CGPoint(x: cx, y: cy - 120), r.name, 150, "TEXT")
            text(CGPoint(x: cx, y: cy + 120), String(format: "%.1fm2 H%d", r.area, r.ceil), 90, "TEXT")
        }
        s += "0\nENDSEC\n0\nEOF\n"
        let url = tmp("\(siteName(site))_도면.dxf")
        do { try s.write(to: url, atomically: true, encoding: .ascii); return url } catch { return nil }
    }
}

// MARK: - 캐드 DXF 불러오기: 닫힌 폴리라인 하나 = 방 하나

enum DXFImport {
    static func rooms(from url: URL) -> [ScanRoom] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let txt = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let rows = txt.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
        var pairs: [(Int, String)] = []
        var i = 0
        while i + 1 < rows.count {
            if let c = Int(rows[i].trimmingCharacters(in: .whitespaces)) { pairs.append((c, rows[i + 1].trimmingCharacters(in: .whitespaces))) }
            i += 2
        }
        var polys: [[CGPoint]] = []
        var inEntities = false
        var cur: [CGPoint] = [], closed = false, kind = "", px: Double? = nil
        func flush() {
            if (kind == "LWPOLYLINE" || kind == "POLYLINE"), cur.count >= 3 {
                let d = hypot(cur[0].x - cur[cur.count - 1].x, cur[0].y - cur[cur.count - 1].y)
                if closed || d < 1 { polys.append(cur) }
            }
            cur = []; closed = false; px = nil
        }
        var k = 0
        while k < pairs.count {
            let (c, v) = pairs[k]
            if c == 2 && v == "ENTITIES" { inEntities = true }
            if c == 0 {
                if v == "ENDSEC" { flush(); kind = ""; inEntities = false }
                else if inEntities {
                    if v == "VERTEX" && kind == "POLYLINE" { px = nil }
                    else if v == "SEQEND" { flush(); kind = "" }
                    else { flush(); kind = v }
                }
            } else if inEntities && (kind == "LWPOLYLINE" || kind == "POLYLINE") {
                if c == 70, let fl = Int(v), cur.isEmpty { closed = fl & 1 == 1 }
                if c == 10 { px = Double(v) }
                if c == 20, let x = px, let y = Double(v) {
                    if !(kind == "POLYLINE" && cur.isEmpty && x == 0 && y == 0 && k < 12) { cur.append(CGPoint(x: x, y: -y)) }
                    px = nil
                }
            }
            k += 1
        }
        flush()
        guard !polys.isEmpty else { return [] }
        // 단위 추정: 전체 크기가 100 미만이면 m, 1000 미만이면 cm 로 봄
        let xs = polys.flatMap { $0.map { $0.x } }, ys = polys.flatMap { $0.map { $0.y } }
        let span = max((xs.max() ?? 0) - (xs.min() ?? 0), (ys.max() ?? 0) - (ys.min() ?? 0))
        let k2: Double = span < 100 ? 1000 : (span < 1500 ? 10 : 1)
        let sid = "dxf-" + uid()
        var out: [ScanRoom] = []
        for p in polys {
            let q = p.map { CGPoint(x: $0.x * k2, y: $0.y * k2) }
            guard let r = PlanGeometry.room(from: q, ops: [], floorY: 0) else { continue }
            var room = ScanRoom(id: uid(), name: "방 \(out.count + 1)", sessionId: sid, x: r.x, y: r.y, rot: r.rot, ceil: 2300, walls: r.walls, usdz: nil, date: Date())
            if room.area < 0.8 { continue }   // 기둥·가구 같은 작은 도형은 뺌
            room.moldType = "none"; room.baseH = 0
            out.append(room)
        }
        return out
    }
}
