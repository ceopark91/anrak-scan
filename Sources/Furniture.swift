import SwiftUI
import RoomPlan
import SceneKit

// MARK: - 스캔한 가구: 종류별 색·이름·간단 모델 (RoomPlan CapturedRoom.objects + iOS 17 속성)
// 참고: Apple "Providing custom models for captured rooms"(카테고리·속성별 모델 바꾸기), jmousseau/RoomObjectReplicator(객체 복제)

/// 방 좌표(mm). x,y = 바닥 중심, w = 가로(물체 x축), d = 깊이, h = 높이, z = 바닥에서 아래 끝, rot = 방 좌표에서 x축 방향(도)
struct AObj: Codable, Hashable { var kind: String; var attr: String = ""; var x: Double; var y: Double; var w: Double; var d: Double; var h: Double; var z: Double = 0; var rot: Double }

enum Furn {
    static let names: [String: String] = [
        "bed": "침대", "sofa": "소파", "table": "책상·식탁", "chair": "의자", "storage": "수납장", "refrigerator": "냉장고",
        "stove": "가스레인지", "oven": "오븐", "dishwasher": "식기세척기", "washerDryer": "세탁기", "sink": "싱크대",
        "toilet": "변기", "bathtub": "욕조", "fireplace": "벽난로", "television": "TV", "stairs": "계단"]
    static func name(_ k: String) -> String { names[k] ?? "가구" }
    /// 종류별 색 (도면·3D 같은 색)
    static func color(_ k: String) -> (Double, Double, Double) {
        switch k {
        case "bed": return (0.55, 0.68, 0.86)
        case "sofa": return (0.55, 0.74, 0.58)
        case "table": return (0.86, 0.66, 0.42)
        case "chair": return (0.93, 0.80, 0.42)
        case "storage": return (0.70, 0.60, 0.82)
        case "refrigerator", "stove", "oven", "dishwasher", "washerDryer": return (0.66, 0.70, 0.74)
        case "sink", "toilet", "bathtub": return (0.48, 0.76, 0.78)
        case "television": return (0.30, 0.32, 0.36)
        case "fireplace": return (0.82, 0.48, 0.40)
        default: return (0.78, 0.76, 0.72)
        }
    }
    static func ui(_ k: String) -> UIColor { let c = color(k); return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1) }
    static func sw(_ k: String) -> Color { let c = color(k); return Color(red: c.0, green: c.1, blue: c.2) }

    static func category(_ c: CapturedRoom.Object.Category) -> String {
        let s = String(describing: c)
        return s.components(separatedBy: CharacterSet(charactersIn: "(.")).first { !$0.isEmpty } ?? s
    }

    /// 스캔 결과 → 방 좌표 가구 목록 (room.toLocal 사용, 라이다 보정 배율 적용)
    static func objects(_ cr: CapturedRoom, room: ScanRoom) -> [AObj] {
        let k = 1000 * LidarCal.scale
        var floorY: Float = cr.floors.first?.transform.columns.3.y ?? (cr.walls.map { $0.transform.columns.3.y - $0.dimensions.y / 2 }.min() ?? 0)
        if let f = cr.floors.first { floorY = f.transform.columns.3.y }
        return cr.objects.map { o in
            let T = o.transform, c = T.columns.3, ax = T.columns.0
            let q = room.toLocal(CGPoint(x: Double(c.x) * k, y: Double(c.z) * k))
            let planAng = atan2(Double(ax.z), Double(ax.x)) * 180 / .pi
            var attr = ""
            if #available(iOS 17.0, *) { attr = o.attributes.map { String(describing: $0) }.joined(separator: ",") }
            let h = Double(o.dimensions.y) * k
            return AObj(kind: category(o.category), attr: attr, x: q.x.rounded(), y: q.y.rounded(),
                        w: (Double(o.dimensions.x) * k).rounded(), d: (Double(o.dimensions.z) * k).rounded(), h: h.rounded(),
                        z: max(0, (Double(c.y - floorY) * k - h / 2).rounded()), rot: planAng - room.rot)
        }
    }

    /// 예전에 스캔한 방: 저장해 둔 원본(JSON)에서 가구 채우기
    @MainActor static func backfill(_ store: Store) {
        var changed = false
        for i in store.site.rooms.indices where store.site.rooms[i].objs == nil {
            guard let raw = store.site.rooms[i].raw,
                  let d = try? Data(contentsOf: Store.docs.appendingPathComponent(raw)),
                  let cr = try? JSONDecoder().decode(CapturedRoom.self, from: d) else { continue }
            store.site.rooms[i].objs = objects(cr, room: store.site.rooms[i]); changed = true
        }
        if changed { store.save() }
    }

    // MARK: 3D 모델 (단순한 모양을 조합: 침대 = 받침+매트리스+헤드+베개, 책상 = 상판+다리 …)
    static func node(_ o: AObj) -> SCNNode {
        let root = SCNNode()
        let W = Float(o.w / 1000), D = Float(o.d / 1000), H = Float(o.h / 1000)
        let main = SCNMaterial(); main.diffuse.contents = ui(o.kind); main.roughness.contents = 0.8
        let light = SCNMaterial(); light.diffuse.contents = UIColor(white: 0.97, alpha: 1)
        let dark = SCNMaterial(); dark.diffuse.contents = UIColor(white: 0.25, alpha: 1)
        func box(_ w: Float, _ h: Float, _ d: Float, _ x: Float, _ y: Float, _ z: Float, _ m: SCNMaterial, _ r: CGFloat = 0.01) {
            guard w > 0.005, h > 0.005, d > 0.005 else { return }
            let g = SCNBox(width: CGFloat(w), height: CGFloat(h), length: CGFloat(d), chamferRadius: min(r, CGFloat(min(w, h, d)) / 2)); g.materials = [m]
            let n = SCNNode(geometry: g); n.position = SCNVector3(x, y + h / 2, z); root.addChildNode(n)
        }
        func cyl(_ r: Float, _ h: Float, _ x: Float, _ y: Float, _ z: Float, _ m: SCNMaterial) {
            let g = SCNCylinder(radius: CGFloat(r), height: CGFloat(h)); g.materials = [m]
            let n = SCNNode(geometry: g); n.position = SCNVector3(x, y + h / 2, z); root.addChildNode(n)
        }
        let a = o.attr.lowercased()
        switch o.kind {
        case "bed":
            box(W, H * 0.45, D, 0, 0, 0, main)
            box(W * 0.97, H * 0.3, D * 0.95, 0, H * 0.45, D * 0.02, light, 0.04)
            box(W, max(H, 0.9), 0.06, 0, 0, -D / 2 + 0.03, main)                  // 헤드
            for s in [-1, 1] as [Float] where W > 1.2 { box(W * 0.38, 0.1, 0.35, s * W * 0.24, H * 0.75, -D / 2 + 0.3, light, 0.04) }
            if W <= 1.2 { box(W * 0.7, 0.1, 0.35, 0, H * 0.75, -D / 2 + 0.3, light, 0.04) }
        case "table":
            let top: Float = 0.04
            if a.contains("circular") || a.contains("elliptic") {
                let g = SCNCylinder(radius: CGFloat(max(W, D) / 2), height: CGFloat(top)); g.materials = [main]
                let n = SCNNode(geometry: g); n.position = SCNVector3(0, H - top / 2, 0); n.scale = SCNVector3(1, 1, D / max(W, D)); root.addChildNode(n)
                cyl(0.04, H - top, 0, 0, 0, dark)
            } else {
                box(W, top, D, 0, H - top, 0, main)
                for sx in [-1, 1] as [Float] { for sz in [-1, 1] as [Float] { box(0.05, H - top, 0.05, sx * (W / 2 - 0.05), 0, sz * (D / 2 - 0.05), main) } }
            }
        case "chair":
            let seat = min(H * 0.5, 0.47)
            if a.contains("stool") {
                cyl(min(W, D) / 2, 0.05, 0, seat - 0.05, 0, main); cyl(0.025, seat - 0.05, 0, 0, 0, dark)
            } else {
                box(W, 0.05, D, 0, seat - 0.05, 0, main)
                box(W, H - seat, 0.05, 0, seat, -D / 2 + 0.025, main)
                if a.contains("swivel") { cyl(0.03, seat - 0.05, 0, 0, 0, dark); cyl(min(W, D) * 0.45, 0.03, 0, 0, 0, dark) }
                else { for sx in [-1, 1] as [Float] { for sz in [-1, 1] as [Float] { box(0.04, seat - 0.05, 0.04, sx * (W / 2 - 0.03), 0, sz * (D / 2 - 0.03), main) } } }
            }
        case "sofa":
            let seat = min(H * 0.55, 0.45)
            box(W, seat, D, 0, 0, 0, main)
            box(W, H - seat, min(0.22, D * 0.3), 0, seat, -D / 2 + min(0.11, D * 0.15), main)
            for s in [-1, 1] as [Float] { box(0.18, max(0.05, H * 0.75 - seat), D, s * (W / 2 - 0.09), seat, 0, main) }
            box(W * 0.9, 0.1, D * 0.65, 0, seat, D * 0.1, light, 0.04)
        case "storage":
            box(W, H, D, 0, 0, 0, main)
            if a.contains("shelf") { var y: Float = 0.35; while y < H - 0.1 { box(W * 0.96, 0.02, 0.01, 0, y, D / 2 + 0.005, light); y += 0.35 } }
            else { let n = max(1, Int((W / 0.45).rounded())); for i in 1..<n { box(0.01, H * 0.96, 0.01, -W / 2 + W * Float(i) / Float(n), H * 0.02, D / 2 + 0.005, light) } }
        case "refrigerator":
            box(W, H, D, 0, 0, 0, main, 0.03); box(W * 0.98, 0.01, 0.01, 0, H * 0.62, D / 2 + 0.005, dark)
            box(0.02, H * 0.25, 0.03, W * 0.4, H * 0.66, D / 2 + 0.015, dark)
        case "television":
            box(W, H, max(0.04, D * 0.3), 0, 0, 0, dark)
        case "sink", "bathtub":
            box(W, H, D, 0, 0, 0, main)
            box(W * 0.85, 0.01, D * 0.75, 0, H - 0.005, 0, light)
        case "toilet":
            box(W * 0.8, H * 0.5, D * 0.6, 0, 0, D * 0.15, light, 0.08); box(W, H, D * 0.25, 0, 0, -D / 2 + D * 0.125, main, 0.03)
        default:
            box(W, H, D, 0, 0, 0, main, 0.02)
        }
        // 이름표
        let t = SCNText(string: name(o.kind), extrusionDepth: 0.002); t.font = UIFont.systemFont(ofSize: 0.12, weight: .semibold); t.flatness = 0.01
        t.materials = [dark]
        let tn = SCNNode(geometry: t); let (mn, mx) = tn.boundingBox
        tn.pivot = SCNMatrix4MakeTranslation((mx.x - mn.x) / 2 + mn.x, 0, 0)
        tn.position = SCNVector3(0, max(H, 0.3) + 0.08, 0)
        tn.constraints = [SCNBillboardConstraint()]
        root.addChildNode(tn)
        return root
    }
}

extension ScanRoom {
    var furnitureSummary: String {
        let c = Dictionary(grouping: objs ?? [], by: \.kind).mapValues(\.count)
        return c.sorted { $0.value > $1.value }.map { "\(Furn.name($0.key)) \($0.value)" }.joined(separator: " · ")
    }
}
