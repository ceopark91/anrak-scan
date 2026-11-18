import SceneKit
import UIKit

/// 벽 길이·천장고·문·창으로 3D(USDZ)를 만든다. 손그림·캐드·직접 고친 방도 3D로 볼 수 있게.
@MainActor
enum Plan3D {
    static let t: Float = 0.12   // 벽 두께(m)

    static func build(_ rooms: [ScanRoom], name: String) -> URL? {
        let scene = SCNScene()
        let wallMat = SCNMaterial(); wallMat.diffuse.contents = UIColor(white: 0.95, alpha: 1); wallMat.roughness.contents = 0.9
        let floorMat = SCNMaterial(); floorMat.diffuse.contents = UIColor(red: 0.79, green: 0.65, blue: 0.48, alpha: 1)
        let trimMat = SCNMaterial(); trimMat.diffuse.contents = UIColor(white: 0.97, alpha: 1)
        let lightMat = SCNMaterial(); lightMat.diffuse.contents = UIColor.white; lightMat.emission.contents = UIColor(red: 1, green: 0.95, blue: 0.84, alpha: 1)
        let doorMat = SCNMaterial(); doorMat.diffuse.contents = UIColor(red: 0.62, green: 0.45, blue: 0.30, alpha: 1)
        let winMat = SCNMaterial(); winMat.diffuse.contents = UIColor(red: 0.7, green: 0.85, blue: 0.95, alpha: 0.35); winMat.transparency = 0.35
        for r in rooms {
            let pts = r.localPoints().map { r.toPlan($0) }
            let n = r.walls.count
            guard n >= 3 else { continue }
            let H = Float(r.ceil) / 1000
            // 바닥
            let path = UIBezierPath()
            for (i, p) in pts.prefix(n).enumerated() {
                let q = CGPoint(x: p.x / 1000, y: -p.y / 1000)
                if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
            }
            path.close()
            let fl = SCNShape(path: path, extrusionDepth: 0.02); fl.materials = [floorMat]
            let fn = SCNNode(geometry: fl); fn.eulerAngles.x = -.pi / 2; fn.position.y = -0.01
            scene.rootNode.addChildNode(fn)
            // 벽
            for i in 0..<n {
                let a = pts[i], b = pts[i + 1]
                let L = Float(hypot(b.x - a.x, b.y - a.y)) / 1000
                guard L > 0.01 else { continue }
                let ang = Float(atan2(b.y - a.y, b.x - a.x))
                let ux = cos(ang), uz = sin(ang)
                let ox = uz * t / 2, oz = -ux * t / 2      // 바깥쪽으로 반 두께
                func box(_ s: Float, _ e: Float, _ y0: Float, _ y1: Float, _ m: SCNMaterial, _ thick: Float) {
                    guard e - s > 0.005, y1 - y0 > 0.005 else { return }
                    // 모서리가 비지 않게 벽 양 끝만 반 두께씩 늘림
                    let s2 = m === wallMat && s < 0.001 ? s - t / 2 : s
                    let e2 = m === wallMat && e > L - 0.001 ? e + t / 2 : e
                    let g = SCNBox(width: CGFloat(e2 - s2), height: CGFloat(y1 - y0), length: CGFloat(thick), chamferRadius: 0)
                    g.materials = [m]
                    let nd = SCNNode(geometry: g)
                    let mid = (s2 + e2) / 2
                    nd.position = SCNVector3(Float(a.x) / 1000 + ux * mid + ox, (y0 + y1) / 2, Float(a.y) / 1000 + uz * mid + oz)
                    nd.eulerAngles.y = -ang
                    scene.rootNode.addChildNode(nd)
                }
                var cut: Float = 0
                let ops = r.walls[i].ops.sorted { $0.off < $1.off }
                for o in ops {
                    let s = Float(o.off) / 1000, e = min(L, s + Float(o.w) / 1000)
                    let sill = Float(o.sill) / 1000, top = min(H, sill + Float(o.h) / 1000)
                    box(cut, s, 0, H, wallMat, t)
                    box(s, e, 0, sill, wallMat, t)          // 창 아래
                    box(s, e, top, H, wallMat, t)           // 문·창 위
                    if o.kind == "window" { box(s, e, sill, top, winMat, 0.02) }
                    else if o.w < 1300 { box(s, e, 0, top, doorMat, 0.04) }   // 문짝 (넓은 개구부는 비움)
                    cut = max(cut, e)
                }
                box(cut, L, 0, H, wallMat, t)
                // 걸레받이(문 자리 빼고)·몰딩: 방 안쪽 면에 붙임
                func trim(_ s: Float, _ e: Float, _ y0: Float, _ y1: Float, _ th: Float) {
                    guard e - s > 0.01, y1 - y0 > 0.002 else { return }
                    let g = SCNBox(width: CGFloat(e - s), height: CGFloat(y1 - y0), length: CGFloat(th), chamferRadius: 0); g.materials = [trimMat]
                    let nd = SCNNode(geometry: g), mid = (s + e) / 2
                    nd.position = SCNVector3(Float(a.x) / 1000 + ux * mid - ox / (t / 2) * th / 2, (y0 + y1) / 2, Float(a.y) / 1000 + uz * mid - oz / (t / 2) * th / 2)
                    nd.eulerAngles.y = -ang; scene.rootNode.addChildNode(nd)
                }
                let bb = Float(r.bb ?? r.baseH ?? 0) / 1000, bbT = max(0.006, Float(r.bbT ?? 9) / 1000)
                if bb > 0 {
                    var c: Float = 0
                    for o in ops where o.kind == "door" { let s = Float(o.off) / 1000; trim(c, s, 0, bb, bbT); c = max(c, s + Float(o.w) / 1000) }
                    trim(c, L, 0, bb, bbT)
                }
                let drop = Float(r.moldDrop) / 1000
                if drop > 0 { trim(0, L, H - drop, H, max(0.015, Float(r.moldProj) / 1000)) }
            }
            // 스캔한 가구: 종류별 색·모양. 등받이·헤드는 가까운 벽 쪽으로
            let poly = Array(r.localPoints().prefix(n))
            func wallDist(_ p: CGPoint) -> Double {
                var m = Double.infinity
                for i in 0..<n { let a = poly[i], b = poly[(i + 1) % n], dx = b.x - a.x, dy = b.y - a.y, L2 = max(1, dx * dx + dy * dy)
                    let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / L2)); m = min(m, hypot(p.x - a.x - dx * t, p.y - a.y - dy * t)) }
                return m
            }
            for o in r.objs ?? [] {
                var la = o.rot * .pi / 180
                let zl = CGPoint(x: -sin(la), y: cos(la))
                let front = CGPoint(x: o.x + zl.x * o.d / 2, y: o.y + zl.y * o.d / 2), back = CGPoint(x: o.x - zl.x * o.d / 2, y: o.y - zl.y * o.d / 2)
                if wallDist(front) < wallDist(back) { la += .pi }
                let nd = Furn.node(o)
                let q = r.toPlan(CGPoint(x: o.x, y: o.y))
                nd.position = SCNVector3(Float(q.x) / 1000, Float(o.z) / 1000, Float(q.y) / 1000)
                nd.eulerAngles.y = -Float(la + r.rot * .pi / 180)
                scene.rootNode.addChildNode(nd)
            }
            // 조명·실링팬 (네모 왼쪽 위 기준 → 방 좌표 → 도면)
            let B = r.box
            for m in r.marks ?? [] {
                let q = r.toPlan(CGPoint(x: B.minX + Double(m.x), y: B.minY + Double(m.y)))
                let px = Float(q.x) / 1000, pz = Float(q.y) / 1000
                if m.k == "fan" {
                    let hub = SCNNode(geometry: SCNCylinder(radius: 0.08, height: 0.12)); hub.geometry?.materials = [trimMat]; hub.position = SCNVector3(px, H - 0.25, pz); scene.rootNode.addChildNode(hub)
                    for k in 0..<3 { let an = Float(k) * 2.094; let bl = SCNNode(geometry: SCNBox(width: 0.55, height: 0.01, length: 0.12, chamferRadius: 0))
                        bl.geometry?.materials = [floorMat]; bl.position = SCNVector3(px + cos(an) * 0.33, H - 0.28, pz + sin(an) * 0.33); bl.eulerAngles.y = -an; scene.rootNode.addChildNode(bl) }
                } else {
                    let d = SCNNode(geometry: SCNCylinder(radius: 0.2, height: 0.05)); d.geometry?.materials = [lightMat]; d.position = SCNVector3(px, H - 0.03, pz); scene.rootNode.addChildNode(d)
                }
            }
        }
        let light = SCNNode(); light.light = SCNLight(); light.light?.type = .ambient; light.light?.intensity = 600
        scene.rootNode.addChildNode(light)
        let sun = SCNNode(); sun.light = SCNLight(); sun.light?.type = .directional; sun.light?.intensity = 800
        sun.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 5, 0); scene.rootNode.addChildNode(sun)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name.isEmpty ? "도면" : name)_3D.usdz")
        try? FileManager.default.removeItem(at: url)
        return scene.write(to: url, options: nil, delegate: nil, progressHandler: nil) ? url : nil
    }
}
