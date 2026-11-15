import Foundation
import SwiftUI
import UIKit

// MARK: - 단가표

struct PriceItem: Codable, Identifiable, Hashable {
    var key: String
    var cat: String
    var name: String
    var unit: String
    var mat: Int      // 자재 단가(원)
    var labor: Int    // 시공 단가(원)
    var id: String { key }
}

/// 예시 단가(2026 기준 대략값) — 거래처 단가로 바꿔 쓰는 전제
let defaultPrices: [PriceItem] = [
    PriceItem(key: "wall_silk", cat: "도배", name: "실크벽지 (106cm×15.6m)", unit: "롤", mat: 45000, labor: 35000),
    PriceItem(key: "wall_hapji", cat: "도배", name: "합지벽지 소폭 (53cm×12.5m)", unit: "롤", mat: 12000, labor: 15000),
    PriceItem(key: "wall_wide", cat: "도배", name: "합지벽지 광폭 (93cm×17.75m)", unit: "롤", mat: 30000, labor: 30000),
    PriceItem(key: "paint", cat: "도장", name: "벽·천장 페인트 (2회)", unit: "㎡", mat: 5000, labor: 9000),
    PriceItem(key: "floor_maru", cat: "바닥", name: "강마루", unit: "평", mat: 110000, labor: 40000),
    PriceItem(key: "floor_jangpan", cat: "바닥", name: "장판 (1.8T)", unit: "평", mat: 35000, labor: 15000),
    PriceItem(key: "floor_tile", cat: "바닥", name: "포세린 타일", unit: "㎡", mat: 60000, labor: 55000),
    PriceItem(key: "mold_flat", cat: "몰딩", name: "천장 평몰딩", unit: "m", mat: 3500, labor: 4000),
    PriceItem(key: "mold_step", cat: "몰딩", name: "천장 계단몰딩", unit: "m", mat: 5500, labor: 4500),
    PriceItem(key: "mold_minus", cat: "몰딩", name: "마이너스 몰딩 (무몰딩)", unit: "m", mat: 9000, labor: 14000),
    PriceItem(key: "baseboard", cat: "몰딩", name: "걸레받이", unit: "m", mat: 5000, labor: 4000),
    PriceItem(key: "door_frame", cat: "몰딩", name: "문선 (문틀 몰딩)", unit: "개", mat: 25000, labor: 20000),
    PriceItem(key: "door_new", cat: "문", name: "방문 교체 (ABS도어)", unit: "개", mat: 250000, labor: 100000),
    PriceItem(key: "door_film", cat: "문", name: "문·문틀 필름", unit: "개", mat: 60000, labor: 90000),
    PriceItem(key: "window_sash", cat: "창호", name: "샤시 교체", unit: "㎡", mat: 330000, labor: 0),
    PriceItem(key: "light", cat: "전기", name: "LED 조명", unit: "개", mat: 60000, labor: 30000),
    PriceItem(key: "outlet", cat: "전기", name: "스위치·콘센트 교체", unit: "개", mat: 8000, labor: 7000),
    PriceItem(key: "demo", cat: "철거", name: "철거 (바닥 면적 기준)", unit: "㎡", mat: 0, labor: 15000),
]

// MARK: - 방별 공사 선택

struct RoomSel: Codable, Hashable {
    var wall = "silk"       // silk, hapji, wide, paint, none
    var ceil = "silk"
    var floor = "none"      // maru, jangpan, tile, none
    var mold = "none"       // flat, step, minus, none
    var base = false
    var doorFrame = 0
    var doorNew = 0
    var doorFilm = 0
    var sash = false
    var lights = 0
    var outlets = 0
    var demo = false
    var qty: [String: Double] = [:]   // 수량 직접 고침 (키 → 값)

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        wall = (try? c.decode(String.self, forKey: .wall)) ?? "silk"
        ceil = (try? c.decode(String.self, forKey: .ceil)) ?? "silk"
        floor = (try? c.decode(String.self, forKey: .floor)) ?? "none"
        mold = (try? c.decode(String.self, forKey: .mold)) ?? "none"
        base = (try? c.decode(Bool.self, forKey: .base)) ?? false
        doorFrame = (try? c.decode(Int.self, forKey: .doorFrame)) ?? 0
        doorNew = (try? c.decode(Int.self, forKey: .doorNew)) ?? 0
        doorFilm = (try? c.decode(Int.self, forKey: .doorFilm)) ?? 0
        sash = (try? c.decode(Bool.self, forKey: .sash)) ?? false
        lights = (try? c.decode(Int.self, forKey: .lights)) ?? 0
        outlets = (try? c.decode(Int.self, forKey: .outlets)) ?? 0
        demo = (try? c.decode(Bool.self, forKey: .demo)) ?? false
        qty = (try? c.decode([String: Double].self, forKey: .qty)) ?? [:]
    }
    enum K: String, CodingKey { case wall, ceil, floor, mold, base, doorFrame, doorNew, doorFilm, sash, lights, outlets, demo, qty }
}

struct ExtraLine: Codable, Identifiable, Hashable {
    var id = uid()
    var cat = "기타"
    var name = ""
    var unit = "식"
    var qty: Double = 1
    var mat = 0
    var labor = 0
}

let extraPresets: [ExtraLine] = [
    ExtraLine(cat: "공통", name: "폐기물 처리", unit: "식", qty: 1, mat: 0, labor: 400000),
    ExtraLine(cat: "공통", name: "현장 보양", unit: "식", qty: 1, mat: 150000, labor: 100000),
    ExtraLine(cat: "공통", name: "입주 청소", unit: "평", qty: 30, mat: 0, labor: 15000),
    ExtraLine(cat: "욕실", name: "욕실 리모델링", unit: "개소", qty: 1, mat: 2500000, labor: 1500000),
    ExtraLine(cat: "주방", name: "싱크대 교체", unit: "m", qty: 3, mat: 450000, labor: 0),
    ExtraLine(cat: "전기", name: "전기 배선 공사", unit: "식", qty: 1, mat: 300000, labor: 500000),
    ExtraLine(cat: "설비", name: "보일러 교체", unit: "대", qty: 1, mat: 900000, labor: 200000),
    ExtraLine(cat: "가구", name: "붙박이장", unit: "자", qty: 8, mat: 180000, labor: 0),
    ExtraLine(cat: "목공", name: "가벽 설치", unit: "㎡", qty: 5, mat: 40000, labor: 50000),
    ExtraLine(cat: "필름", name: "인테리어 필름", unit: "m", qty: 10, mat: 15000, labor: 20000),
]

struct EstLine: Identifiable, Hashable {
    var id: String { room + key }
    var room: String
    var key: String
    var cat: String
    var name: String
    var unit: String
    var qty: Double
    var auto: Double      // 스캔으로 계산한 값
    var note: String
    var mat: Int
    var labor: Int
    var matSum: Int { Int((qty * Double(mat)).rounded()) }
    var laborSum: Int { Int((qty * Double(labor)).rounded()) }
    var sum: Int { matSum + laborSum }
}

// MARK: - 계산

enum Calc {
    static let py = 3.3058   // ㎡ / 평

    /// 장 길이들을 롤에 채워 롤 수 (긴 것부터, 들어가는 첫 롤에)
    static func rolls(_ strips: [Int], rollLen: Int) -> Int {
        var left: [Int] = []
        for s in strips.sorted(by: >) {
            if let i = left.firstIndex(where: { $0 >= s }) { left[i] -= s }
            else { left.append(rollLen - s) }
        }
        return left.count
    }

    /// 벽 도배 장 목록 (mm): 높이+100, 문·창 위아래는 짧은 장
    static func wallStrips(_ r: ScanRoom, width: Int) -> [Int] {
        var out: [Int] = []
        let full = r.paperH + 100
        let top = r.ceil - (((r.moldType ?? "none") == "none") ? 0 : (r.moldH ?? 0))   // 도배 윗선
        let bottom = r.baseH ?? 0                                                      // 도배 아랫선
        for w in r.walls {
            var n = Int(ceil(Double(w.len) / Double(width)))
            for o in w.ops {
                let k = o.w / width          // 문·창 폭 안에 다 들어가는 장 수
                guard k > 0 else { continue }
                n -= k
                let above = top - (o.sill + o.h)
                if above > 30 { out += Array(repeating: above + 100, count: k) }
                let below = o.sill - bottom
                if o.kind == "window", below > 30 { out += Array(repeating: below + 100, count: k) }
            }
            out += Array(repeating: full, count: max(0, n))
        }
        return out
    }

    /// 천장 도배 장 목록: 긴 방향으로, 짧은 변 / 폭 만큼
    static func ceilStrips(_ r: ScanRoom, width: Int) -> [Int] {
        let (a, b) = r.ceilingBox
        let long = max(a, b), short = min(a, b)
        let n = Int(ceil(Double(short) / Double(width)))
        return Array(repeating: long + 100, count: n)
    }

    static func paperSpec(_ k: String) -> (key: String, width: Int, roll: Int)? {
        switch k {
        case "silk": return ("wall_silk", 1060, 15600)
        case "hapji": return ("wall_hapji", 530, 12500)
        case "wide": return ("wall_wide", 930, 17750)
        default: return nil
        }
    }

    static func lines(_ r: ScanRoom, _ s: RoomSel, _ P: [String: PriceItem]) -> [EstLine] {
        var out: [EstLine] = []
        func add(_ key: String, _ auto: Double, _ note: String, tag: String = "") {
            guard let p = P[key], auto > 0 else { return }
            let id = key + tag
            let q = s.qty[id] ?? auto
            out.append(EstLine(room: r.id, key: id, cat: p.cat, name: p.name + (tag.isEmpty ? "" : " · \(tag == ".c" ? "천장" : "벽")"),
                               unit: p.unit, qty: q, auto: auto, note: note, mat: p.mat, labor: p.labor))
        }
        let ceilArea = r.area
        // 벽
        if let sp = paperSpec(s.wall) {
            let st = wallStrips(r, width: sp.width)
            add(sp.key, Double(rolls(st, rollLen: sp.roll)), "\(st.count)장 · 도배 높이 \(mm(r.paperH))", tag: ".w")
        } else if s.wall == "paint" {
            add("paint", (r.wallArea * 10).rounded() / 10, "벽 면적(문·창 뺌)", tag: ".w")
        }
        // 천장
        if let sp = paperSpec(s.ceil) {
            let st = ceilStrips(r, width: sp.width)
            add(sp.key, Double(rolls(st, rollLen: sp.roll)), "\(st.count)장 × \(mm(st.first ?? 0))", tag: ".c")
        } else if s.ceil == "paint" {
            add("paint", (ceilArea * 10).rounded() / 10, "천장 면적", tag: ".c")
        }
        // 바닥 (로스 5%)
        switch s.floor {
        case "maru": add("floor_maru", (ceilArea / py * 1.05 * 10).rounded() / 10, "\(String(format: "%.1f", ceilArea))㎡ + 로스 5%")
        case "jangpan": add("floor_jangpan", (ceilArea / py * 1.05 * 10).rounded() / 10, "\(String(format: "%.1f", ceilArea))㎡ + 로스 5%")
        case "tile": add("floor_tile", (ceilArea * 1.08 * 10).rounded() / 10, "\(String(format: "%.1f", ceilArea))㎡ + 로스 8%")
        default: break
        }
        // 몰딩 (둘레 + 10%)
        let per = Double(r.perimeter) / 1000
        let allOps: [AOp] = r.walls.flatMap { $0.ops }
        var doorMM = 0
        var winArea = 0.0
        for o in allOps {
            if o.kind == "door" { doorMM += o.w }
            if o.kind == "window" { winArea += Double(o.w) * Double(o.h) / 1_000_000 }
        }
        let doorW = Double(doorMM) / 1000
        if ["flat", "step", "minus"].contains(s.mold) {
            add("mold_" + s.mold, (per * 1.1 * 10).rounded() / 10, "둘레 \(String(format: "%.2f", per))m + 10%")
        }
        if s.base { add("baseboard", ((per - doorW) * 1.1 * 10).rounded() / 10, "둘레 − 문 폭 + 10%") }
        add("door_frame", Double(s.doorFrame), "")
        add("door_new", Double(s.doorNew), "")
        add("door_film", Double(s.doorFilm), "")
        if s.sash {
            add("window_sash", (winArea * 10).rounded() / 10, "스캔한 창 넓이 합")
        }
        add("light", Double(s.lights), "")
        add("outlet", Double(s.outlets), "")
        if s.demo { add("demo", (ceilArea * 10).rounded() / 10, "바닥 면적") }
        return out
    }

    struct Total { var mat = 0, labor = 0, sub = 0, margin = 0, vat = 0, sum = 0 }

    static func total(_ lines: [EstLine], _ extras: [ExtraLine], marginPct: Double, vat: Bool) -> Total {
        var t = Total()
        for l in lines { t.mat += l.matSum; t.labor += l.laborSum }
        for e in extras { t.mat += Int(e.qty * Double(e.mat)); t.labor += Int(e.qty * Double(e.labor)) }
        t.sub = t.mat + t.labor
        t.margin = Int((Double(t.sub) * marginPct / 100).rounded())
        t.vat = vat ? Int((Double(t.sub + t.margin) * 0.1).rounded()) : 0
        t.sum = (t.sub + t.margin + t.vat) / 1000 * 1000   // 천원 아래 절사
        return t
    }
}

func won(_ v: Int) -> String {
    let f = NumberFormatter(); f.numberStyle = .decimal
    return (f.string(from: NSNumber(value: v)) ?? "\(v)")
}
func qtyStr(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }
