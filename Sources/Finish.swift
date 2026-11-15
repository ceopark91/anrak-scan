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
            }
            .navigationTitle("방 정보").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("저장") { save(); dismiss() }.fontWeight(.semibold) }
            }
            .onAppear {
                if let r = store.site.rooms.first(where: { $0.id == roomId }) {
                    name = r.name; mold = r.moldType ?? "none"; moldH = r.moldH ?? 0; base = r.baseH ?? 0; ceil = r.ceil
                }
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
    func save() {
        guard let i = store.site.rooms.firstIndex(where: { $0.id == roomId }) else { return }
        var r = store.site.rooms[i]
        r.name = name.isEmpty ? r.name : name
        r.moldType = mold; r.moldH = mold == "none" ? 0 : moldH; r.baseH = max(0, base)
        if ceil > 1500, ceil < 6000 { r.ceil = ceil }
        store.site.rooms[i] = r
    }
}
