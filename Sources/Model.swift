import Foundation
import SwiftUI

// 안락실측 백업 형식과 같은 구조 (벽은 ①번부터 시계 방향, turn = "R" | "L" | 각도)
struct AOp: Codable, Identifiable, Hashable {
    var id: String
    var kind: String   // "door" | "window"
    var off: Int       // 벽 시작점에서 문·창 왼쪽 끝까지(mm)
    var w: Int
    var h: Int
    var sill: Int      // 바닥에서 아래 끝까지(mm)
}

struct AWall: Codable, Hashable {
    var len: Int
    var turn: String   // "R", "L" 또는 "123.4"
    var ops: [AOp]

    var turnDeg: Double {
        switch turn {
        case "R": return 90
        case "L": return -90
        default: return Double(turn) ?? 0
        }
    }
}

struct ScanRoom: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var sessionId: String
    var x: Double          // 첫 모서리 위치(mm, 도면 좌표 · y는 아래쪽이 +)
    var y: Double
    var rot: Double        // 첫 벽 방향(도)
    var ceil: Int          // 천장 높이(mm)
    var walls: [AWall]
    var usdz: String?      // Documents 안 파일 이름
    var raw: String? = nil  // RoomPlan 원본(CapturedRoom JSON) 파일 이름 → STL
    var date: Date

    /// 안락실측 geo()와 같은 계산: 방 안쪽 모서리 점(방 좌표)
    func localPoints() -> [CGPoint] {
        var x = 0.0, y = 0.0, a = 0.0
        var pts = [CGPoint(x: 0, y: 0)]
        for w in walls {
            let r = a * .pi / 180
            x += cos(r) * Double(w.len); y += sin(r) * Double(w.len)
            pts.append(CGPoint(x: x, y: y))
            a += w.turnDeg
        }
        return pts
    }
    /// 방 좌표 → 도면 좌표 (안락실측 xf())
    func toPlan(_ p: CGPoint, dx: Double = 0, dy: Double = 0) -> CGPoint {
        let r = rot * .pi / 180, c = cos(r), s = sin(r)
        return CGPoint(x: p.x * c - p.y * s + x + dx, y: p.x * s + p.y * c + y + dy)
    }
    var area: Double {   // ㎡
        let p = localPoints(); let n = walls.count
        guard n >= 3 else { return 0 }
        var s = 0.0
        for i in 0..<n { let a = p[i], b = p[(i + 1) % n]; s += a.x * b.y - b.x * a.y }
        return abs(s) / 2 / 1_000_000
    }
    var perimeter: Int { walls.reduce(0) { $0 + $1.len } }
    /// 벽 도배 면적(㎡, 문·창 뺀 값)
    var wallArea: Double {
        let h = Double(ceil)
        var s = Double(perimeter) * h
        for w in walls { for o in w.ops { s -= Double(o.w * o.h) } }
        return max(0, s) / 1_000_000
    }
    /// 천장 가로×세로(첫 벽 방향 기준 외접 사각형, mm)
    var ceilingBox: (Int, Int) {
        let p = localPoints()
        let xs = p.map { $0.x }, ys = p.map { $0.y }
        return (Int(((xs.max() ?? 0) - (xs.min() ?? 0)).rounded()), Int(((ys.max() ?? 0) - (ys.min() ?? 0)).rounded()))
    }
}

struct Site: Codable {
    var name: String = ""
    var addr: String = ""
    var rooms: [ScanRoom] = []
    var offsets: [String: [Double]] = [:]   // 스캔 묶음(세션)마다 도면 위치 보정
}

let roomTypes = ["거실", "주방", "거실·주방", "안방", "작은방", "아이방", "드레스룸", "욕실", "현관", "다용도실", "발코니", "기타"]

func uid() -> String { String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(9)) }

@MainActor
final class Store: ObservableObject {
    @Published var site = Site() { didSet { save() } }

    static var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private var file: URL { Store.docs.appendingPathComponent("site.json") }

    init() {
        if let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(Site.self, from: d) { site = s }
    }
    func save() {
        if let d = try? JSONEncoder().encode(site) { try? d.write(to: file, options: .atomic) }
    }

    func offset(for r: ScanRoom) -> (Double, Double) {
        let o = site.offsets[r.sessionId] ?? [0, 0]
        return (o[0], o[1])
    }

    /// 새 방 추가. 앱을 껐다 켜면 좌표 원점이 바뀌므로, 새 스캔 묶음의 첫 방은 기존 도면 오른쪽에 놓는다.
    func add(_ room: ScanRoom) {
        var s = site
        if s.offsets[room.sessionId] == nil {
            if s.rooms.isEmpty {
                s.offsets[room.sessionId] = [0, 0]
            } else {
                let old = planBounds(s.rooms, s.offsets)
                let pts = room.localPoints().map { room.toPlan($0) }
                let minX = pts.map { $0.x }.min() ?? 0, minY = pts.map { $0.y }.min() ?? 0
                s.offsets[room.sessionId] = [old.maxX + 1000 - minX, old.minY - minY]
            }
        }
        s.rooms.append(room)
        site = s
    }

    func delete(_ room: ScanRoom) {
        for f in [room.usdz, room.raw].compactMap({ $0 }) { try? FileManager.default.removeItem(at: Store.docs.appendingPathComponent(f)) }
        site.rooms.removeAll { $0.id == room.id }
    }

    /// 안락실측 [백업 불러오기]용 JSON
    func exportAnrakJSON() -> URL? {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let rooms: [[String: Any]] = site.rooms.map { r in
            let (dx, dy) = offset(for: r)
            return [
                "id": r.id, "name": r.name, "type": roomTypes.contains(r.name) ? r.name : "",
                "ceil": r.ceil, "x": (r.x + dx).rounded(), "y": (r.y + dy).rounded(), "rot": r.rot,
                "floor": "oak", "wall": "white",
                "walls": r.walls.map { w -> [String: Any] in
                    let turn: Any = (w.turn == "R" || w.turn == "L") ? w.turn : (Double(w.turn) ?? 0)
                    return ["len": w.len, "turn": turn,
                            "ops": w.ops.map { ["id": $0.id, "kind": $0.kind, "off": $0.off, "w": $0.w, "h": $0.h, "sill": $0.sill] }]
                },
                "memo": "안락 스캔(라이다)으로 잰 치수 · 오차 ±2cm 안팎, 시공 전 주요 치수는 줄자로 확인",
                "photos": [Any]()
            ]
        }
        let name = site.name.isEmpty ? "라이다 스캔 현장" : site.name
        let project: [String: Any] = [
            "id": uid(), "name": name, "client": "", "addr": site.addr,
            "date": df.string(from: Date()),
            "memo": "아이폰 라이다로 스캔한 도면 (방 \(site.rooms.count)개)",
            "wallT": 150, "rooms": rooms, "created": Int(Date().timeIntervalSince1970 * 1000)
        ]
        let root: [String: Any] = ["app": "anrak-measure", "v": 1, "project": project]
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        let safe = name.replacingOccurrences(of: "/", with: "_")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe)_안락실측.json")
        try? data.write(to: url, options: .atomic)
        return url
    }
}

struct Bounds { var minX, minY, maxX, maxY: Double }

func planBounds(_ rooms: [ScanRoom], _ offsets: [String: [Double]]) -> Bounds {
    var b = Bounds(minX: .infinity, minY: .infinity, maxX: -.infinity, maxY: -.infinity)
    for r in rooms {
        let o = offsets[r.sessionId] ?? [0, 0]
        for p in r.localPoints() {
            let q = r.toPlan(p, dx: o[0], dy: o[1])
            b.minX = min(b.minX, q.x); b.minY = min(b.minY, q.y); b.maxX = max(b.maxX, q.x); b.maxY = max(b.maxY, q.y)
        }
    }
    if !b.minX.isFinite { b = Bounds(minX: 0, minY: 0, maxX: 1000, maxY: 1000) }
    return b
}
