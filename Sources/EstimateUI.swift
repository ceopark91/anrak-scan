import SwiftUI

// MARK: - 견적 탭

struct EstimateTab: View {
    @EnvironmentObject var store: Store
    @State private var share: URL?
    @State private var addExtra = false

    var priceMap: [String: PriceItem] { Dictionary(uniqueKeysWithValues: store.prices.map { ($0.key, $0) }) }

    func sel(_ id: String) -> Binding<RoomSel> {
        Binding(get: { store.site.est[id] ?? RoomSel() }, set: { store.site.est[id] = $0 })
    }
    var allLines: [EstLine] {
        let P = priceMap
        return store.site.rooms.flatMap { Calc.lines($0, store.site.est[$0.id] ?? RoomSel(), P) }
    }

    var body: some View {
        let lines = allLines
        let t = Calc.total(lines, store.site.extras, marginPct: store.site.marginPct, vat: store.site.vat)
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("견적").font(.title2.weight(.bold)).padding(.horizontal, 4).padding(.top, 8)
                if store.site.rooms.isEmpty {
                    Card { Text("도면 탭에서 방을 먼저 스캔하거나 불러오세요. 방 치수로 수량이 자동 계산됩니다.").foregroundStyle(.secondary) }
                }
                ForEach(store.site.rooms) { r in
                    RoomEstimateCard(room: r, sel: sel(r.id), lines: lines.filter { $0.room == r.id })
                }
                extrasCard
                totalCard(t)
                BigButton(title: "견적서 PDF 보내기", icon: "doc.text", dark: true) {
                    share = Exporter.estimatePDF(store.site, lines: lines, total: t)
                }
                Text("단가는 [단가] 탭의 값으로 계산합니다. 처음 들어 있는 값은 예시이니 거래처 단가로 바꿔 쓰세요.")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)
            }
            .padding(16)
        }
        .background(bg.ignoresSafeArea())
        .scrollDismissesKeyboard(.interactively)
        .sheet(item: Binding(get: { share.map { ShareItem(url: $0) } }, set: { share = $0?.url })) { ShareSheet(items: [$0.url]) }
    }

    var extrasCard: some View {
        Card {
            HStack {
                Text("추가 공사").font(.headline)
                Spacer()
                Menu {
                    Button("빈 항목 직접 입력") { store.site.extras.append(ExtraLine()) }
                    ForEach(extraPresets) { p in
                        Button("\(p.cat) · \(p.name)") { var e = p; e.id = uid(); store.site.extras.append(e) }
                    }
                } label: { Label("추가", systemImage: "plus").font(.subheadline.weight(.semibold)) }
            }
            if store.site.extras.isEmpty {
                Text("욕실·주방·전기·가구 등 어떤 공사든 항목으로 넣을 수 있습니다.").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach($store.site.extras) { $e in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("공사 이름", text: $e.name).font(.subheadline.weight(.semibold))
                        Button { store.site.extras.removeAll { $0.id == e.id } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Color(white: 0.75)) }
                    }
                    HStack(spacing: 8) {
                        NumField(title: "수량", value: $e.qty).frame(width: 64)
                        TextField("단위", text: $e.unit).textFieldStyle(.roundedBorder).frame(width: 52)
                        IntField(title: "자재 단가", value: $e.mat)
                        IntField(title: "시공 단가", value: $e.labor)
                    }
                    Text("= \(won(Int(e.qty * Double(e.mat + e.labor))))원").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
    }

    func totalCard(_ t: Calc.Total) -> some View {
        Card {
            row("자재비", t.mat); row("시공비", t.labor)
            Divider()
            HStack {
                Text("이윤·관리비").font(.subheadline)
                Spacer()
                Stepper("\(Int(store.site.marginPct))%", value: $store.site.marginPct, in: 0...40, step: 1).fixedSize()
                Text("\(won(t.margin))원").font(.subheadline).frame(minWidth: 90, alignment: .trailing)
            }
            Toggle(isOn: $store.site.vat) { Text("부가세 10%  \(store.site.vat ? won(t.vat) + "원" : "")").font(.subheadline) }.tint(.black)
            Divider()
            HStack { Text("합계").font(.headline); Spacer(); Text("\(won(t.sum))원").font(.title3.weight(.bold)) }
        }
    }
    func row(_ k: String, _ v: Int) -> some View {
        HStack { Text(k).font(.subheadline); Spacer(); Text("\(won(v))원").font(.subheadline) }
    }
}

struct NumField: View {
    let title: String
    @Binding var value: Double
    var body: some View {
        TextField(title, value: $value, format: .number).keyboardType(.decimalPad).textFieldStyle(.roundedBorder)
    }
}
struct IntField: View {
    let title: String
    @Binding var value: Int
    var body: some View {
        TextField(title, value: $value, format: .number).keyboardType(.numberPad).textFieldStyle(.roundedBorder)
    }
}

struct RoomEstimateCard: View {
    @EnvironmentObject var store: Store
    let room: ScanRoom
    @Binding var sel: RoomSel
    let lines: [EstLine]
    @State private var open = true

    let papers: [(String, String)] = [("none", "안 함"), ("silk", "실크"), ("hapji", "합지 소폭"), ("wide", "합지 광폭"), ("paint", "페인트")]
    let floors: [(String, String)] = [("none", "안 함"), ("maru", "강마루"), ("jangpan", "장판"), ("tile", "타일")]
    let molds: [(String, String)] = [("none", "안 함"), ("flat", "평몰딩"), ("step", "계단몰딩"), ("minus", "마이너스")]

    var body: some View {
        Card {
            Button { open.toggle() } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(room.name).font(.headline)
                        Text("\(String(format: "%.1f", room.area / Calc.py))평 · 둘레 \(String(format: "%.1f", Double(room.perimeter) / 1000))m · 도배 높이 \(mm(room.paperH))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(won(lines.reduce(0) { $0 + $1.sum }))원").font(.subheadline.weight(.semibold))
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.caption).foregroundStyle(.secondary)
                }
            }.foregroundStyle(.black)
            if open {
                ChipRow(title: "벽", options: papers, sel: $sel.wall)
                ChipRow(title: "천장", options: papers, sel: $sel.ceil)
                ChipRow(title: "바닥", options: floors, sel: $sel.floor)
                ChipRow(title: "천장 몰딩 (새로 시공)", options: molds, sel: $sel.mold)
                Toggle("걸레받이 새로 시공", isOn: $sel.base).font(.subheadline).tint(.black)
                Toggle("철거", isOn: $sel.demo).font(.subheadline).tint(.black)
                Toggle("샤시 교체", isOn: $sel.sash).font(.subheadline).tint(.black)
                count("문선(문틀 몰딩)", $sel.doorFrame); count("방문 교체", $sel.doorNew); count("문·문틀 필름", $sel.doorFilm)
                count("조명", $sel.lights); count("스위치·콘센트", $sel.outlets)
                if !lines.isEmpty {
                    Divider()
                    ForEach(lines) { l in lineRow(l) }
                }
            }
        }
    }

    func count(_ title: String, _ v: Binding<Int>) -> some View {
        Stepper(value: v, in: 0...50) { Text("\(title)  \(v.wrappedValue)").font(.subheadline) }
    }

    func lineRow(_ l: EstLine) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(l.name).font(.subheadline)
                if !l.note.isEmpty { Text(l.note).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    TextField("", value: Binding(get: { l.qty }, set: { v in
                        if abs(v - l.auto) < 0.001 { sel.qty[l.key] = nil } else { sel.qty[l.key] = v }
                    }), format: .number)
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    .frame(width: 54).padding(4).background(Color(white: 0.95), in: RoundedRectangle(cornerRadius: 6))
                    Text(l.unit).font(.caption)
                }
                Text("\(won(l.sum))원").font(.caption).foregroundStyle(.secondary)
                if sel.qty[l.key] != nil {
                    Button("자동 \(qtyStr(l.auto))") { sel.qty[l.key] = nil }.font(.caption2)
                }
            }
        }
    }
}

// MARK: - 단가 탭

struct PriceTab: View {
    @EnvironmentObject var store: Store
    @State private var confirmReset = false

    var cats: [String] {
        var seen: [String] = []
        for p in store.prices where !seen.contains(p.cat) { seen.append(p.cat) }
        return seen
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("단가표").font(.title2.weight(.bold)).padding(.horizontal, 4).padding(.top, 8)
                Text("자재 단가 / 시공 단가(원). 고치면 견적에 바로 반영됩니다.").font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)
                ForEach(cats, id: \.self) { c in
                    Card {
                        Text(c).font(.headline)
                        ForEach($store.prices) { $p in
                            if p.cat == c {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(p.name)  ·  \(p.unit)").font(.subheadline)
                                    HStack(spacing: 8) { IntField(title: "자재", value: $p.mat); IntField(title: "시공", value: $p.labor) }
                                }
                            }
                        }
                    }
                }
                Button("예시 단가로 되돌리기") { confirmReset = true }.font(.subheadline).foregroundStyle(.red).padding(.horizontal, 4)
            }
            .padding(16)
        }
        .background(bg.ignoresSafeArea())
        .scrollDismissesKeyboard(.interactively)
        .confirmationDialog("단가를 처음 값으로 되돌릴까요?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("되돌리기", role: .destructive) { store.prices = defaultPrices }
        }
    }
}
