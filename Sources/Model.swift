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

/// 천장 기물 (조명·에어컨 등). x, y = 방 좌표(mm, 첫 모서리 기준)
struct Fixture: Codable, Hashable, Identifiable {
    var id: String
    var kind: String
    var x: Double
    var y: Double
}
let fixtureKinds: [(String, String)] = [("light", "조명"), ("down", "매입등"), ("aircon", "천장 에어컨"), ("sprinkler", "스프링클러"),
                                        ("detector", "화재감지기"), ("vent", "환기구"), ("hatch", "점검구"), ("etc", "기타")]
func fixtureName(_ k: String) -> String { fixtureKinds.first { $0.0 == k }?.1 ?? "기타" }

/// 도배계산기·웹앱과 같은 이름(단위 mm). 몰딩 k: none | flat(평몰딩, h=벽 높이) | crown(각몰딩, w=폭, a=각도)
struct AMold: Codable, Hashable { var k: String = "none"; var h: Int = 40; var w: Int = 60; var a: Int = 45 }
/// 우물천장: 방이 감싸는 네모 왼쪽 위에서 x,y, 가로 a, 세로 b, 깊이 d
struct AWell: Codable, Hashable { var x: Int; var y: Int; var a: Int; var b: Int; var d: Int = 120 }
/// 천장 조명(light)·실링팬(fan): 방이 감싸는 네모 왼쪽 위에서 x,y
struct AMark: Codable, Hashable { var k: String; var x: Int; var y: Int }

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
    var fixtures: [Fixture]? = nil  // 천장 기물
    var moldType: String? = nil   // 현재 천장 몰딩: none, flat, step, minus
    var moldH: Int? = nil         // 몰딩 높이(mm)
    var baseH: Int? = nil         // 현재 걸레받이 높이(mm), 0이면 없음
    var mold: AMold? = nil        // 몰딩 자세히(각몰딩 각도 등) → moldH 자동
    var bb: Int? = nil            // 걸레받이 높이 (baseH와 같게 유지)
    var bbT: Int? = nil           // 걸레받이 두께
    var ceilT: String? = nil      // flat | well
    var wells: [AWell]? = nil
    var marks: [AMark]? = nil
    var objs: [AObj]? = nil       // 스캔한 가구 (방 좌표)
    var elec: [AElec]? = nil      // 콘센트·스위치 (바닥에서 높이)
    /// 도배하는 벽 높이 = 천장 높이 − 몰딩 − 걸레받이
    var paperH: Int { max(300, ceil - ((moldType ?? "none") == "none" ? 0 : (moldH ?? 0)) - (baseH ?? 0)) }
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
    /// 도면 좌표 → 방 좌표 (toPlan의 반대)
    func toLocal(_ p: CGPoint) -> CGPoint {
        let r = -rot * .pi / 180, c = cos(r), s = sin(r)
        let dx = p.x - x, dy = p.y - y
        return CGPoint(x: dx * c - dy * s, y: dx * s + dy * c)
    }
    /// 몰딩이 벽에 내려오는 높이 / 천장에 나오는 폭
    var moldDrop: Int { guard let m = mold else { return (moldType ?? "none") == "none" ? 0 : (moldH ?? 0) }
        return m.k == "flat" ? m.h : m.k == "crown" ? Int((Double(m.w) * sin(Double(m.a) * .pi / 180)).rounded()) : 0 }
    var moldProj: Int { guard let m = mold, m.k == "crown" else { return 0 }; return Int((Double(m.w) * cos(Double(m.a) * .pi / 180)).rounded()) }
    /// 방이 감싸는 네모(방 좌표)
    var box: CGRect { let p = localPoints().prefix(walls.count); let xs = p.map(\.x), ys = p.map(\.y)
        guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return .zero }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0) }
    func count(_ kind: String) -> Int { (fixtures ?? []).filter { $0.kind == kind }.count }
    /// 방 좌표 → 도면 좌표 (안락실측 xf())
    func toPlan(_ p: CGPoint, dx: Double = 0, dy: Double = 0) -> CGPoint {
        let r = rot * .pi / 180, c = cos(r), s = sin(r)
        return CGPoint(x: p.x * c - p.y * s + x + dx, y: p.x * s + p.y * c + y + dy)
    }
    /// 벽을 다 돌고 났을 때 시작점과 어긋난 거리(mm)
    var gap: Int { let p = localPoints(); guard let l = p.last else { return 0 }; return Int(hypot(l.x, l.y).rounded()) }
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

struct Site: Codable, Identifiable {
    var id: String = uid()
    var name: String = ""
    var addr: String = ""
    var rooms: [ScanRoom] = []
    var offsets: [String: [Double]] = [:]   // 스캔 묶음(세션)마다 도면 위치 보정
    var align: Double? = nil                // 도면 정렬 각도(도). nil이면 벽 방향으로 자동
    var turn: Int = 0                       // 추가로 90° 단위 돌리기
    var est: [String: RoomSel] = [:]        // 방 id → 공사 선택
    var extras: [ExtraLine] = []
    var marginPct: Double = 10
    var vat: Bool = true
    var memos: [MeasureMemo] = []          // 사진 실측 메모
    var checks: [String: SiteCheck] = [:]  // 현장 확인 목록

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? uid()
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        addr = (try? c.decode(String.self, forKey: .addr)) ?? ""
        rooms = (try? c.decode([ScanRoom].self, forKey: .rooms)) ?? []
        offsets = (try? c.decode([String: [Double]].self, forKey: .offsets)) ?? [:]
        align = try? c.decode(Double.self, forKey: .align)
        turn = (try? c.decode(Int.self, forKey: .turn)) ?? 0
        est = (try? c.decode([String: RoomSel].self, forKey: .est)) ?? [:]
        extras = (try? c.decode([ExtraLine].self, forKey: .extras)) ?? []
        marginPct = (try? c.decode(Double.self, forKey: .marginPct)) ?? 10
        vat = (try? c.decode(Bool.self, forKey: .vat)) ?? true
        memos = (try? c.decode([MeasureMemo].self, forKey: .memos)) ?? []
        checks = (try? c.decode([String: SiteCheck].self, forKey: .checks)) ?? [:]
    }
    enum K: String, CodingKey { case id, name, addr, rooms, offsets, align, turn, est, extras, marginPct, vat, memos, checks }

    /// 벽 방향(길이 가중) 으로 구한 정렬 각도: 이 각도만큼 돌리면 벽이 수평·수직이 됨
    var autoAlign: Double {
        var sx = 0.0, sy = 0.0
        for r in rooms {
            var a = r.rot
            for w in r.walls {
                let t = 4 * a * .pi / 180
                sx += cos(t) * Double(w.len); sy += sin(t) * Double(w.len)
                a += w.turnDeg
            }
        }
        if sx == 0 && sy == 0 { return 0 }
        return atan2(sy, sx) * 180 / .pi / 4
    }
    var viewAngle: Double { -(align ?? autoAlign) + Double(turn) * 90 }

    /// 위치 보정 + 정렬을 적용한 방 (그림·내보내기는 모두 이것으로)
    func placed(_ r: ScanRoom) -> ScanRoom {
        let o = offsets[r.sessionId] ?? [0, 0]
        let a = viewAngle * .pi / 180, c = cos(a), s = sin(a)
        let x = r.x + o[0], y = r.y + o[1]
        var q = r
        q.x = x * c - y * s; q.y = x * s + y * c; q.rot = r.rot + viewAngle
        return q
    }
    var placedRooms: [ScanRoom] { rooms.map(placed) }
}

let roomTypes = ["거실", "주방", "거실·주방", "안방", "작은방", "아이방", "드레스룸", "욕실", "현관", "다용도실", "발코니", "기타"]

let webAppURL = "https://claude.ai/artifact/JmJXisKBGoFivgHyRkBVcZ"

func uid() -> String { String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(9)) }

@MainActor
final class Store: ObservableObject {
    @Published var site = Site() { didSet { save() } }
    @Published var prices: [PriceItem] = defaultPrices { didSet { savePrices() } }
    private var priceFile: URL { Store.docs.appendingPathComponent("prices.json") }
    func savePrices() { if let d = try? JSONEncoder().encode(prices) { try? d.write(to: priceFile, options: .atomic) } }

    static var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private var file: URL { Store.docs.appendingPathComponent("site.json") }

    init() {
        if let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(Site.self, from: d) { site = s }
        if let d = try? Data(contentsOf: othersFile), let o = try? JSONDecoder().decode([Site].self, from: d) { others = o }
        if let d = try? Data(contentsOf: priceFile), let p = try? JSONDecoder().decode([PriceItem].self, from: d) {
            // 저장된 단가 + 새로 생긴 항목
            var m = p
            for q in defaultPrices where !m.contains(where: { $0.key == q.key }) { m.append(q) }
            prices = m
        }
    }
    func save() {
        if let d = try? JSONEncoder().encode(site) { try? d.write(to: file, options: .atomic) }
    }

    // 다른 현장들 (지금 열어 둔 현장은 site)
    @Published var others: [Site] = [] { didSet { saveOthers() } }
    @Published var openScan = false   // 웹앱에서 스캔 요청
    private var othersFile: URL { Store.docs.appendingPathComponent("others.json") }
    func saveOthers() { if let d = try? JSONEncoder().encode(others) { try? d.write(to: othersFile, options: .atomic) } }
    func newSite() { others.insert(site, at: 0); site = Site() }
    func open(_ id: String) {
        guard let i = others.firstIndex(where: { $0.id == id }) else { return }
        let next = others[i]
        var o = others; o.remove(at: i); o.insert(site, at: 0)
        others = o; site = next
    }
    /// 지금 현장을 지우고 다른 현장(없으면 빈 현장)을 연다
    func deleteCurrentSite() {
        for r in site.rooms { for f in [r.usdz, r.raw].compactMap({ $0 }) { try? FileManager.default.removeItem(at: Store.docs.appendingPathComponent(f)) } }
        for m in site.memos { for f in [m.photo, m.depth].compactMap({ $0 }) { try? FileManager.default.removeItem(at: Store.docs.appendingPathComponent(f)) } }
        if others.isEmpty { site = Site() } else { var o = others; let next = o.removeFirst(); others = o; site = next }
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
        let rooms: [[String: Any]] = site.placedRooms.map { r in
            let (dx, dy) = (0.0, 0.0)
            return [
                "id": r.id, "name": r.name, "type": roomTypes.contains(r.name) ? r.name : "",
                "ceil": r.ceil, "x": (r.x + dx).rounded(), "y": (r.y + dy).rounded(), "rot": (r.rot * 10).rounded() / 10,
                "floor": "oak", "wall": "white",
                "walls": r.walls.map { w -> [String: Any] in
                    let turn: Any = (w.turn == "R" || w.turn == "L") ? w.turn : (Double(w.turn) ?? 0)
                    return ["len": w.len, "turn": turn,
                            "ops": w.ops.map { ["id": $0.id, "kind": $0.kind, "off": $0.off, "w": $0.w, "h": $0.h, "sill": $0.sill] }]
                },
                "mold": ["k": (r.mold ?? AMold(k: (r.moldType ?? "none") == "none" ? "none" : "flat", h: r.moldH ?? 40)).k,
                         "h": (r.mold?.h ?? r.moldH ?? 40), "w": r.mold?.w ?? 60, "a": r.mold?.a ?? 45],
                "bb": r.bb ?? r.baseH ?? 0, "bbT": r.bbT ?? 9, "ceilT": r.ceilT ?? "flat",
                "wells": (r.wells ?? []).map { ["x": $0.x, "y": $0.y, "a": $0.a, "b": $0.b, "d": $0.d] },
                "marks": (r.marks ?? []).map { ["k": $0.k, "x": $0.x, "y": $0.y] },
                "objs": (r.objs ?? []).map { ["kind": $0.kind, "x": $0.x.rounded(), "y": $0.y.rounded(), "w": $0.w, "d": $0.d, "h": $0.h, "rot": ($0.rot * 10).rounded() / 10] as [String: Any] },
                "elec": (r.elec ?? []).map { ["k": $0.k, "h": $0.h, "n": $0.n] as [String: Any] },
                "memo": "안락 스캔(라이다)으로 잰 치수 · 오차 ±2cm 안팎, 시공 전 주요 치수는 줄자로 확인",
                "photos": [Any]()
            ]
        }
        let name = site.name.isEmpty ? "라이다 스캔 현장" : site.name
        let project: [String: Any] = [
            "id": uid(), "name": name, "client": "", "addr": site.addr,
            "date": df.string(from: Date()),
            "memo": "아이폰 라이다로 스캔한 도면 (방 \(site.rooms.count)개)",
            "wallT": 150, "rooms": rooms,
            "checks": site.checks.mapValues { ["state": $0.state, "note": $0.note] as [String: Any] }, "created": Int(Date().timeIntervalSince1970 * 1000)
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
