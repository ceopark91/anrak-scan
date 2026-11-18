import SwiftUI

/// 현재 마감 상태(스캔으로 못 잡는 것): 천장 몰딩·걸레받이
let moldOptions: [(String, String, Int)] = [("none", "없음", 0), ("flat", "평몰딩", 40), ("step", "계단몰딩", 60), ("minus", "마이너스", 10)]
let baseOptions: [Int] = [0, 60, 80, 100]

struct ChipRow<T: Hashable>: View {
    let title: String
    let options: [(T, String)]
    @Binding var sel: T
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(options, id: \.0) { o in
                        Button(o.1) { sel = o.0 }
                            .font(.subheadline)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(sel == o.0 ? Color.black : Color(white: 0.93), in: Capsule())
                            .foregroundStyle(sel == o.0 ? .white : .black)
                    }
                }
            }
        }
    }
}

struct FinishPicker: View {
    @Binding var mold: String
    @Binding var base: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ChipRow(title: "지금 천장 몰딩", options: moldOptions.map { ($0.0, $0.1) }, sel: $mold)
            ChipRow(title: "지금 걸레받이", options: baseOptions.map { ($0, $0 == 0 ? "없음" : "\($0)mm") }, sel: $base)
        }
    }
}

func moldHeight(_ t: String) -> Int { moldOptions.first { $0.0 == t }?.2 ?? 0 }
func moldName(_ t: String?) -> String { moldOptions.first { $0.0 == (t ?? "none") }?.1 ?? "없음" }

/// 방 정보 고치기 (이름·몰딩·걸레받이·천장 높이, 카메라 자로 재기)
struct RoomEditSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let roomId: String
    @State private var name = ""
    @State private var mold = "none"
    @State private var moldH = 0
    @State private var base = 0
    @State private var ceil = 2300
    @State private var measure: IdString?
    @State private var walls: [AWall] = []
    @State private var fixtures: [Fixture] = []
    @ObservedObject var laser = LaserLink.shared
    @State private var laserWall: Int? = nil   // 레이저 값이 들어갈 벽 순번

    var body: some View {
        NavigationStack {
            Form {
                Section("방 이름") {
                    ChipRow(title: "", options: roomTypes.map { ($0, $0) }, sel: $name)
                    TextField("직접 입력", text: $name)
                }
                Section {
                    ChipRow(title: "지금 천장 몰딩", options: moldOptions.map { ($0.0, $0.1) }, sel: $mold)
                        .onChange(of: mold) { _, v in if moldH == 0 || moldOptions.contains(where: { $0.2 == moldH }) { moldH = moldHeight(v) } }
                    if mold != "none" { measureRow("몰딩 높이", $moldH, "mold") }
                    measureRow("걸레받이 높이", $base, "base")
                } header: { Text("몰딩 · 걸레받이") } footer: {
                    Text("라이다 스캔은 몰딩·걸레받이를 따로 못 잡습니다. [재기]로 카메라 자를 써서 잰 값을 넣으면 도배 높이에서 빠지고, 견적의 몰딩·걸레받이에도 반영됩니다. 걸레받이가 없으면 0.")
                }
                Section("천장 높이") { measureRow("바닥~천장", $ceil, "ceil") }
                Section {
                    ForEach(fixtureKinds, id: \.0) { k in
                        let n = fixtures.filter { $0.kind == k.0 }.count
                        Stepper(value: Binding(get: { n }, set: { v in
                            if v > n { for _ in n..<v { fixtures.append(Fixture(id: uid(), kind: k.0, x: Double(walls.first?.len ?? 2000) / 2, y: 600)) } }
                            else if v < n { for _ in v..<n { if let i = fixtures.lastIndex(where: { $0.kind == k.0 }) { fixtures.remove(at: i) } } }
                        }), in: 0...40) { Text("\(k.1)  \(n)") }
                    }
                } header: { Text("천장 기물") } footer: {
                    Text("스캔 중 천장을 가리키고 눌러 찍은 것은 위치까지 도면에 나옵니다. 여기서 늘린 것은 개수만 셉니다(견적 조명 수량에 반영).")
                }
                if laser.connected {
                    Section {
                        Toggle("레이저로 벽 1부터 차례대로 받기", isOn: Binding(get: { laserWall != nil }, set: { laserWall = $0 ? 0 : nil }))
                        if let w = laserWall, w < walls.count { Text("지금: 벽 \(w + 1) 차례 · 벽 끝에서 끝까지 쏘세요").font(.caption).foregroundStyle(.green) }
                    } header: { Text("레이저 측정기") }
                }
                Section {
                    ForEach(walls.indices, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("벽 \(i + 1)").fontWeight(.semibold).foregroundStyle(laserWall == i ? Color.green : Color.primary)
                                    .onTapGesture { if laser.connected { laserWall = i } }
                                Spacer()
                                TextField("0", value: $walls[i].len, format: .number).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 80)
                                Text("mm").foregroundStyle(.secondary)
                                Menu {
                                    Button("문 추가") { walls[i].ops.append(AOp(id: uid(), kind: "door", off: max(0, walls[i].len / 2 - 450), w: 900, h: 2100, sill: 0)) }
                                    Button("창 추가") { walls[i].ops.append(AOp(id: uid(), kind: "window", off: max(0, walls[i].len / 2 - 600), w: 1200, h: 1200, sill: 900)) }
                                } label: { Image(systemName: "plus.circle") }
                            }
                            ForEach(walls[i].ops.indices, id: \.self) { k in
                                HStack(spacing: 6) {
                                    Text(walls[i].ops[k].kind == "door" ? "문" : "창").font(.caption.weight(.semibold)).frame(width: 18)
                                    opField("위치", $walls[i].ops[k].off); opField("폭", $walls[i].ops[k].w)
                                    opField("높이", $walls[i].ops[k].h); opField("턱", $walls[i].ops[k].sill)
                                    Button { walls[i].ops.remove(at: k) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Color(white: 0.7)) }
                                        .buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                } header: { Text("벽 · 문 · 창 (줄자로 잰 값으로 고치기)") } footer: {
                    Text("벽 1부터 시계 방향입니다. 위치는 벽 시작점에서 문·창 왼쪽 끝까지, 턱은 바닥에서 창 아래까지입니다.")
                }
            }
            .navigationTitle("방 정보").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("저장") { save(); dismiss() }.fontWeight(.semibold) }
            }
            .onAppear {
                if let r = store.site.rooms.first(where: { $0.id == roomId }) {
                    name = r.name; mold = r.moldType ?? "none"; moldH = r.moldH ?? 0; base = r.baseH ?? 0; ceil = r.ceil; walls = r.walls; fixtures = r.fixtures ?? []
                }
            }
            .onChange(of: laser.seq) { _, _ in
                guard let v = laser.lastMM, let w = laserWall, w < walls.count else { return }
                walls[w].len = Int((Double(v) / 10).rounded()) * 10
                laserWall = w + 1 < walls.count ? w + 1 : nil
            }
            .fullScreenCover(item: $measure) { m in
                MeasureScreen(title: m.id == "mold" ? "몰딩 높이 재기" : m.id == "base" ? "걸레받이 높이 재기" : "천장 높이 재기") { v in
                    if m.id == "mold" { moldH = v } else if m.id == "base" { base = v } else { ceil = v }
                }
            }
        }
    }
    func measureRow(_ title: String, _ v: Binding<Int>, _ key: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("0", value: v, format: .number).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 70)
            Text("mm").foregroundStyle(.secondary)
            Button("재기") { measure = IdString(id: key) }.buttonStyle(.bordered)
        }
    }
    func opField(_ title: String, _ v: Binding<Int>) -> some View {
        VStack(spacing: 0) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            TextField("0", value: v, format: .number).keyboardType(.numberPad).multilineTextAlignment(.center).font(.footnote)
        }
    }
    func save() {
        guard let i = store.site.rooms.firstIndex(where: { $0.id == roomId }) else { return }
        var r = store.site.rooms[i]
        r.name = name.isEmpty ? r.name : name
        if walls.count == r.walls.count, walls.allSatisfy({ $0.len > 0 }) { r.walls = walls }
        r.fixtures = fixtures
        r.moldType = mold; r.moldH = mold == "none" ? 0 : moldH; r.baseH = max(0, base)
        if ceil > 1500, ceil < 6000 { r.ceil = ceil }
        store.site.rooms[i] = r
    }
}
