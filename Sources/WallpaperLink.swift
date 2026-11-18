import Foundation
import SwiftUI

// MARK: - 안락 도배계산기로 보내기
// 계산기 형식(normAI와 같은 모양) + 문·창·천장 정보. 단위 cm.
// 방은 창 벽을 위로 둔 그림(아래가 +y)에서 시계 방향, 변 방향 R·D·L·U.
// 문·창 x = 그 벽 안쪽에서 보고 왼쪽 끝에서(시계 방향이면 벽 시작점 = 왼쪽 끝).
// 우물·조명 x,y = 감싸는 네모 왼쪽 위(창 벽 쪽)에서.

enum WallpaperLink {
    static let appURL = "https://anrak-wallpaper.xyur789.workers.dev"

    static func cm(_ mm: Int) -> Double { (Double(mm) / 10 * 10).rounded() / 10 }
    static func cm(_ mm: Double) -> Double { (mm / 10 * 10).rounded() / 10 }

    /// 한 방 → 계산기 방 (직각 방만; 사선 벽 있으면 nil)
    static func room(_ r: ScanRoom) -> [String: Any]? {
        let n = r.walls.count
        guard n >= 4 else { return nil }
        let P = Array(r.localPoints().prefix(n))
        // 창 벽: 창이 있는 가장 긴 벽, 없으면 가장 긴 벽
        let idx = Array(0..<n)
        let winWalls = idx.filter { i in r.walls[i].ops.contains { $0.kind == "window" } }
        let pool = winWalls.isEmpty ? idx : winWalls
        var wi = pool[0]
        for i in pool where r.walls[i].len > r.walls[wi].len { wi = i }
        // 창 벽이 +x 방향이 되게 돌림 (y 아래로, 시계 방향 유지 → 방 안쪽이 아래)
        let a = P[wi], b = P[(wi + 1) % n]
        let th = atan2(b.y - a.y, b.x - a.x), c = cos(-th), s = sin(-th)
        func rot(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * c - p.y * s, y: p.x * s + p.y * c) }
        let Q = P.map(rot)
        let minX = Q.map(\.x).min() ?? 0, minY = Q.map(\.y).min() ?? 0
        // 변 방향
        var edges: [[String: Any]] = []
        for i in 0..<n {
            let p = Q[i], q = Q[(i + 1) % n]
            let ang = atan2(q.y - p.y, q.x - p.x) * 180 / .pi
            let k = Int((ang / 90).rounded())
            guard abs(ang - Double(k) * 90) < 2 else { return nil }      // 사선 벽은 아직 못 보냄
            let dir = ["R", "D", "L", "U"][((k % 4) + 4) % 4]
            let w = r.walls[i]
            let ops: [[String: Any]] = w.ops.map { o in
                var d: [String: Any] = ["k": o.kind == "door" ? "door" : "win", "x": cm(o.off), "w": cm(o.w), "h": cm(o.h)]
                if o.kind == "window" { d["s"] = cm(o.sill) }
                return d
            }
            edges.append(["dir": dir, "len": cm(w.len), "ops": ops])
        }
        // 천장 좌표: 방 좌표(감싸는 네모 왼쪽 위 기준) → 돌린 그림의 네모 왼쪽 위 기준
        let bx = r.box.minX, by = r.box.minY
        func tr(_ x: Double, _ y: Double) -> CGPoint { let p = rot(CGPoint(x: x + bx, y: y + by)); return CGPoint(x: p.x - minX, y: p.y - minY) }
        let wells: [[String: Any]] = (r.wells ?? []).map { w in
            let p1 = tr(Double(w.x), Double(w.y)), p2 = tr(Double(w.x + w.a), Double(w.y + w.b))
            let x0 = Double(min(p1.x, p2.x)), y0 = Double(min(p1.y, p2.y))
            let aw = Double(abs(p2.x - p1.x)), bh = Double(abs(p2.y - p1.y))
            return ["x": cm(x0), "y": cm(y0), "a": cm(aw), "b": cm(bh), "d": cm(w.d)]
        }
        let marks: [[String: Any]] = (r.marks ?? []).map { m in let p = tr(Double(m.x), Double(m.y)); return ["k": m.k, "x": cm(Double(p.x)), "y": cm(Double(p.y))] }
        let m = r.mold ?? AMold(k: (r.moldType ?? "none") == "none" ? "none" : "flat", h: r.moldH ?? 0)
        return ["name": r.name, "edges": edges, "window": wi, "CH": cm(r.ceil), "bb": cm(r.bb ?? r.baseH ?? 0),
                "mold": ["k": m.k, "h": cm(m.h), "w": cm(m.w), "a": m.a],
                "ceilT": r.ceilT ?? "flat", "wells": wells, "marks": marks]
    }

    /// 현장 전체 → JSON 글자 (보낸 방 수, 못 보낸 방 이름)
    static func json(_ site: Site) -> (text: String, sent: Int, skipped: [String])? {
        var rooms: [[String: Any]] = [], skipped: [String] = []
        for r in site.rooms { if let d = room(r) { rooms.append(d) } else { skipped.append(r.name) } }
        guard !rooms.isEmpty else { return nil }
        let obj: [String: Any] = ["source": "anrak-scan", "v": 1, "unit": "cm", "site": site.name, "rooms": rooms,
                                  "note": skipped.isEmpty ? "" : "사선 벽이 있는 방은 빠짐: " + skipped.joined(separator: ", ")]
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), let t = String(data: d, encoding: .utf8) else { return nil }
        return (t, rooms.count, skipped)
    }
}
