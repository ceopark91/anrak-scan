import Foundation
import RoomPlan
import simd

// RoomPlan 결과(CapturedRoom) → 안락실측 방 한 개
// 도면 좌표: 세계 x → 도면 x, 세계 z → 도면 y (위에서 내려다본 그림, 아래쪽이 +), 단위 mm

struct PlanOp { var kind: String; var c: CGPoint; var w: Double; var h: Double; var sill: Double }

enum PlanGeometry {
    /// 거의 일직선인 모서리·아주 짧은 벽 없애기
    static func simplify(_ input: [CGPoint], minEdge: Double = 80, minTurn: Double = 4) -> [CGPoint] {
        var q = input
        if q.count >= 2, hypot(q[0].x - q[q.count - 1].x, q[0].y - q[q.count - 1].y) < 1 { q.removeLast() }
        var changed = true
        while changed && q.count > 3 {
            changed = false
            // 짧은 변: 두 점을 가운데로 합침
            for i in 0..<q.count {
                let a = q[i], b = q[(i + 1) % q.count]
                if hypot(b.x - a.x, b.y - a.y) < minEdge {
                    let m = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                    let j = (i + 1) % q.count
                    q[i] = m; q.remove(at: j)
                    changed = true; break
                }
            }
            if changed { continue }
            // 일직선 점
            for i in 0..<q.count {
                let p = q[(i - 1 + q.count) % q.count], c = q[i], n = q[(i + 1) % q.count]
                let a1 = atan2(c.y - p.y, c.x - p.x), a2 = atan2(n.y - c.y, n.x - c.x)
                var t = (a2 - a1) * 180 / .pi
                while t > 180 { t -= 360 }; while t <= -180 { t += 360 }
                if abs(t) < minTurn { q.remove(at: i); changed = true; break }
            }
        }
        return q
    }

    /// 모서리 점 → 안락실측 벽 목록 (안락실측 roomFromPoints와 같은 규칙)
    static func room(from pts: [CGPoint], ops: [PlanOp], floorY: Double) -> (walls: [AWall], x: Double, y: Double, rot: Double)? {
        var q = simplify(pts)
        guard q.count >= 3 else { return nil }
        var s2 = 0.0
        for i in 0..<q.count { let a = q[i], b = q[(i + 1) % q.count]; s2 += a.x * b.y - b.x * a.y }
        if s2 < 0 { q = [q[0]] + q.dropFirst().reversed() }   // 시계 방향으로
        let n = q.count
        var ang: [Double] = []
        for i in 0..<n { let a = q[i], b = q[(i + 1) % n]; ang.append(atan2(b.y - a.y, b.x - a.x) * 180 / .pi) }
        var walls: [AWall] = []
        for i in 0..<n {
            let a = q[i], b = q[(i + 1) % n]
            var t = ang[(i + 1) % n] - ang[i]
            while t > 180 { t -= 360 }; while t <= -180 { t += 360 }
            t = (t * 10).rounded() / 10
            let turn = abs(t - 90) < 1.5 ? "R" : abs(t + 90) < 1.5 ? "L" : String(t)
            let len = Int((hypot(b.x - a.x, b.y - a.y) / 10).rounded()) * 10
            walls.append(AWall(len: len, turn: turn, ops: []))
        }
        // 문·창을 가장 가까운 벽에 붙임
        for o in ops {
            var best: (i: Int, d: Double, t: Double)? = nil
            for i in 0..<n {
                let a = q[i], b = q[(i + 1) % n]
                let L = hypot(b.x - a.x, b.y - a.y); guard L > 1 else { continue }
                let ux = (b.x - a.x) / L, uy = (b.y - a.y) / L
                let vx = o.c.x - a.x, vy = o.c.y - a.y
                let t = vx * ux + vy * uy
                let d = abs(vx * uy - vy * ux)
                if t > -150, t < L + 150, d < 450, best == nil || d < best!.d { best = (i, d, t) }
            }
            guard let bst = best else { continue }
            let L = Double(walls[bst.i].len)
            let w = min(o.w, L)
            let off = max(0, min(L - w, bst.t - w / 2))
            let r10 = { (v: Double) in Int((v / 10).rounded()) * 10 }
            walls[bst.i].ops.append(AOp(id: uid(), kind: o.kind, off: r10(off), w: r10(w), h: r10(o.h), sill: max(0, r10(o.sill))))
        }
        for i in 0..<n { walls[i].ops.sort { $0.off < $1.off } }
        return (walls, Double(q[0].x), Double(q[0].y), (ang[0] * 10).rounded() / 10)
    }

    /// 바닥 윤곽이 없을 때: 벽 선분을 이어 모서리를 구함
    static func outline(fromWalls segs: [(CGPoint, CGPoint)]) -> [CGPoint] {
        guard segs.count >= 3 else { return [] }
        var order: [(CGPoint, CGPoint)] = [segs[0]]
        var used = Set([0])
        while used.count < segs.count {
            let end = order.last!.1
            var best: (j: Int, d: Double, flip: Bool)? = nil
            for j in 0..<segs.count where !used.contains(j) {
                let d0 = hypot(segs[j].0.x - end.x, segs[j].0.y - end.y)
                let d1 = hypot(segs[j].1.x - end.x, segs[j].1.y - end.y)
                let d = min(d0, d1)
                if best == nil || d < best!.d { best = (j, d, d1 < d0) }
            }
            guard let b = best, b.d < 1500 else { break }
            used.insert(b.j)
            order.append(b.flip ? (segs[b.j].1, segs[b.j].0) : segs[b.j])
        }
        guard order.count >= 3 else { return [] }
        var pts: [CGPoint] = []
        for i in 0..<order.count {
            let p = order[(i - 1 + order.count) % order.count], c = order[i]
            pts.append(intersect(p.0, p.1, c.0, c.1) ?? CGPoint(x: (p.1.x + c.0.x) / 2, y: (p.1.y + c.0.y) / 2))
        }
        return pts
    }

    static func intersect(_ a1: CGPoint, _ a2: CGPoint, _ b1: CGPoint, _ b2: CGPoint) -> CGPoint? {
        let d1 = CGPoint(x: a2.x - a1.x, y: a2.y - a1.y), d2 = CGPoint(x: b2.x - b1.x, y: b2.y - b1.y)
        let cr = d1.x * d2.y - d1.y * d2.x
        let l1 = hypot(d1.x, d1.y), l2 = hypot(d2.x, d2.y)
        guard l1 > 1, l2 > 1, abs(cr) / (l1 * l2) > 0.17 else { return nil }   // 약 10° 미만이면 평행으로 봄
        let t = ((b1.x - a1.x) * d2.y - (b1.y - a1.y) * d2.x) / cr
        return CGPoint(x: a1.x + d1.x * t, y: a1.y + d1.y * t)
    }
}

extension simd_float4x4 {
    var pos: simd_float3 { simd_float3(columns.3.x, columns.3.y, columns.3.z) }
    var xAxis: simd_float3 { simd_normalize(simd_float3(columns.0.x, columns.0.y, columns.0.z)) }
}

private func plan(_ v: simd_float3) -> CGPoint { CGPoint(x: Double(v.x) * 1000, y: Double(v.z) * 1000) }

enum RoomConverter {
    static func convert(_ room: CapturedRoom, name: String, sessionId: String, usdz: String?) -> ScanRoom? {
        // 바닥 높이
        var floorY: Float
        if let f = room.floors.first { floorY = f.transform.pos.y }
        else { floorY = room.walls.map { $0.transform.pos.y - $0.dimensions.y / 2 }.min() ?? 0 }

        // 천장 높이 = 벽 높이의 가운데 값
        let hs = room.walls.map { Double($0.dimensions.y) * 1000 }.sorted()
        let ceil = hs.isEmpty ? 2300 : Int((hs[hs.count / 2] / 10).rounded()) * 10

        // 벽 선분 (바닥 윤곽 검산 + 바닥 윤곽이 없을 때 대신 씀)
        let segs: [(CGPoint, CGPoint)] = room.walls.map { w in
            let c = w.transform.pos, u = w.transform.xAxis * (w.dimensions.x / 2)
            return (plan(c - u), plan(c + u))
        }
        func box(_ p: [CGPoint]) -> [Double] {
            [p.map { $0.x }.min() ?? 0, p.map { $0.y }.min() ?? 0, p.map { $0.x }.max() ?? 0, p.map { $0.y }.max() ?? 0]
        }
        let wallBox = box(segs.flatMap { [$0.0, $0.1] })

        // 방 윤곽: 가장 넓은 바닥의 윤곽(바닥 좌표 → 세계 좌표). 벽 범위와 크게 다르면 벽으로 만든 윤곽을 씀
        var pts: [CGPoint] = []
        if let f = room.floors.max(by: { $0.dimensions.x * $0.dimensions.z < $1.dimensions.x * $1.dimensions.z }),
           f.polygonCorners.count >= 3 {
            let local = f.polygonCorners.map { c -> CGPoint in
                let w = f.transform * simd_float4(c.x, c.y, c.z, 1)
                return plan(simd_float3(w.x, w.y, w.z))
            }
            let raw = f.polygonCorners.map { plan($0) }
            if segs.count >= 3 {
                let score = { (p: [CGPoint]) -> Double in zip(box(p), wallBox).reduce(0) { $0 + abs($1.0 - $1.1) } }
                let best = score(local) <= score(raw) ? local : raw
                pts = score(best) < 1200 ? best : []
            } else {
                pts = local
            }
        }
        if pts.count < 3 { pts = PlanGeometry.outline(fromWalls: segs) }

        var ops: [PlanOp] = []
        func addOps(_ list: [CapturedRoom.Surface], _ kind: String) {
            for s in list {
                let c = s.transform.pos
                let bottom = Double(c.y - s.dimensions.y / 2 - floorY) * 1000
                ops.append(PlanOp(kind: kind, c: plan(c), w: Double(s.dimensions.x) * 1000, h: Double(s.dimensions.y) * 1000, sill: bottom))
            }
        }
        addOps(room.doors, "door")
        addOps(room.openings, "door")
        addOps(room.windows, "window")

        guard let r = PlanGeometry.room(from: pts, ops: ops, floorY: Double(floorY)) else { return nil }
        return ScanRoom(id: uid(), name: name, sessionId: sessionId, x: r.x, y: r.y, rot: r.rot, ceil: ceil,
                        walls: r.walls, usdz: usdz, date: Date())
    }
}
