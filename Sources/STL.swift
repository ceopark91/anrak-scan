import Foundation
import RoomPlan
import simd

/// 스캔한 방들을 STL(바이너리, 단위 mm, Z가 위)로 내보내기
/// 벽·문·창·가구 = RoomPlan이 잡은 상자, 바닥 = 방 윤곽 판(두께 20mm)
@MainActor
enum STLExport {
    struct Tri { var a, b, c: simd_float3 }

    static func build(store: Store) -> URL? {
        var tris: [Tri] = []
        for r in store.site.rooms {
            let (dx, dy) = store.offset(for: r)
            // 세계(m, Y 위) → STL(mm, Z 위). 도면 y = 세계 z 이므로 STL y = -(도면 y)
            func P(_ w: simd_float3) -> simd_float3 {
                simd_float3(w.x * 1000 + Float(dx), -(w.z * 1000 + Float(dy)), w.y * 1000)
            }
            var floorY: Float = 0
            if let f = r.raw, let room = load(f) {
                floorY = room.floors.first?.transform.columns.3.y
                    ?? (room.walls.map { $0.transform.columns.3.y - $0.dimensions.y / 2 }.min() ?? 0)
                for w in room.walls { tris += box(w.transform, simd_float3(w.dimensions.x, w.dimensions.y, 0.10), P) }
                for s in room.doors + room.openings { tris += box(s.transform, simd_float3(s.dimensions.x, s.dimensions.y, 0.14), P) }
                for s in room.windows { tris += box(s.transform, simd_float3(s.dimensions.x, s.dimensions.y, 0.14), P) }
                for o in room.objects { tris += box(o.transform, o.dimensions, P) }
            }
            // 바닥판: 도면 윤곽 (방 좌표 → 도면 → STL)
            let pts = r.localPoints().dropLast().map { r.toPlan($0, dx: dx, dy: dy) }
            let base = floorY * 1000
            let top = pts.map { simd_float3(Float($0.x), -Float($0.y), base) }
            let bot = pts.map { simd_float3(Float($0.x), -Float($0.y), base - 20) }
            for (i, j, k) in earClip(pts) {
                tris.append(Tri(a: top[i], b: top[j], c: top[k]))
                tris.append(Tri(a: bot[k], b: bot[j], c: bot[i]))
            }
            for i in 0..<top.count {
                let j = (i + 1) % top.count
                tris.append(Tri(a: top[i], b: bot[i], c: bot[j])); tris.append(Tri(a: top[i], b: bot[j], c: top[j]))
            }
        }
        guard !tris.isEmpty else { return nil }
        let name = (store.site.name.isEmpty ? "라이다 스캔" : store.site.name).replacingOccurrences(of: "/", with: "_")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)_mm.stl")
        try? write(tris, to: url)
        return url
    }

    static func load(_ file: String) -> CapturedRoom? {
        guard let d = try? Data(contentsOf: Store.docs.appendingPathComponent(file)) else { return nil }
        return try? JSONDecoder().decode(CapturedRoom.self, from: d)
    }

    /// 상자(가운데·방향 = transform, 크기 = 가로·높이·두께) → 삼각형 12개
    static func box(_ t: simd_float4x4, _ d: simd_float3, _ P: (simd_float3) -> simd_float3) -> [Tri] {
        let h = d / 2
        var v: [simd_float3] = []
        for z in [-h.z, h.z] { for y in [-h.y, h.y] { for x in [-h.x, h.x] {
            let w = t * simd_float4(x, y, z, 1); v.append(P(simd_float3(w.x, w.y, w.z)))
        } } }
        // 0:---,1:+--,2:-+-,3:++-,4:--+,5:+-+,6:-++,7:+++
        let f: [(Int, Int, Int, Int)] = [(0, 2, 3, 1), (4, 5, 7, 6), (0, 1, 5, 4), (2, 6, 7, 3), (0, 4, 6, 2), (1, 3, 7, 5)]
        var out: [Tri] = []
        for (a, b, c, e) in f { out.append(Tri(a: v[a], b: v[b], c: v[c])); out.append(Tri(a: v[a], b: v[c], c: v[e])) }
        return out
    }

    /// 단순 다각형 귀 자르기 삼각분할
    static func earClip(_ p: [CGPoint]) -> [(Int, Int, Int)] {
        var idx = Array(0..<p.count)
        guard idx.count >= 3 else { return [] }
        var area = 0.0
        for i in 0..<p.count { let a = p[i], b = p[(i + 1) % p.count]; area += a.x * b.y - b.x * a.y }
        let sgn: Double = area >= 0 ? 1 : -1
        func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Double { (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) }
        var out: [(Int, Int, Int)] = []
        var guardN = 0
        while idx.count > 3 && guardN < 10000 {
            guardN += 1
            var cut = false
            for k in 0..<idx.count {
                let i0 = idx[(k - 1 + idx.count) % idx.count], i1 = idx[k], i2 = idx[(k + 1) % idx.count]
                if cross(p[i0], p[i1], p[i2]) * sgn <= 0 { continue }
                var inside = false
                for j in idx where j != i0 && j != i1 && j != i2 {
                    let c1 = cross(p[i0], p[i1], p[j]) * sgn, c2 = cross(p[i1], p[i2], p[j]) * sgn, c3 = cross(p[i2], p[i0], p[j]) * sgn
                    if c1 > 0 && c2 > 0 && c3 > 0 { inside = true; break }
                }
                if inside { continue }
                out.append((i0, i1, i2)); idx.remove(at: k); cut = true; break
            }
            if !cut { break }
        }
        if idx.count == 3 { out.append((idx[0], idx[1], idx[2])) }
        return out
    }

    static func write(_ tris: [Tri], to url: URL) throws {
        var d = Data(count: 80)
        var n = UInt32(tris.count); d.append(Data(bytes: &n, count: 4))
        func put(_ v: simd_float3) { var x = v.x, y = v.y, z = v.z
            d.append(Data(bytes: &x, count: 4)); d.append(Data(bytes: &y, count: 4)); d.append(Data(bytes: &z, count: 4)) }
        for t in tris {
            let c = simd_cross(t.b - t.a, t.c - t.a); let l = simd_length(c)
            put(l > 0 ? c / l : simd_float3(0, 0, 1)); put(t.a); put(t.b); put(t.c)
            var attr: UInt16 = 0; d.append(Data(bytes: &attr, count: 2))
        }
        try d.write(to: url, options: .atomic)
    }
}
