import SwiftUI

// MARK: - 현장 누락 방지: 실측 때 자주 빠뜨려 다시 가게 되는 것들 (국내 인테리어 업체 실측 자료 기준)

struct SiteCheck: Codable, Hashable { var state: Int = 0; var note = "" }   // 0 아직 · 1 확인 · 2 해당 없음

let siteCheckItems: [(key: String, title: String, hint: String, need: Bool)] = [
    ("drain", "배수 위치", "욕실·베란다·주방 배수구 위치와 벽에서 거리", true),
    ("step", "바닥 단차", "방·거실·베란다·현관 문턱 높이 차이", true),
    ("wtr", "방수턱", "욕실·베란다 방수턱 높이·폭", true),
    ("heat", "난방 분배기", "분배기 위치·보일러실, 바닥 공사 범위", true),
    ("light", "경량벽 여부", "두드려 봐서 비는 벽(석고) 표시 → 선반·TV 고정 가능 여부", true),
    ("elec", "콘센트·스위치 높이", "바닥에서 높이, 개수, 옮길 것", true),
    ("defect", "하자 사진", "곰팡이·누수 흔적·벽 갈라짐·바닥 들뜸을 사진 메모로", true),
    ("window", "샷시·창 상태", "유리·손잡이·실리콘, 교체 범위", false),
    ("ceil", "천장 누수·처짐", "얼룩, 점검구 위치", false),
    ("door", "문·문틀 크기", "문짝 앞뒤, 문틀 폭·옆면 (필름 견적)", false),
    ("mold", "몰딩·걸레받이", "깊이·높이, 철거 여부", false),
    ("ac", "에어컨 배관", "배관 구멍·실외기 자리", false),
    ("gas", "가스·수도 배관", "가스 밸브·수도 위치, 옮길 것", false),
    ("breaker", "두꺼비집", "분전반 위치, 회로 수", false),
]

extension Site {
    var checkMissing: [String] { siteCheckItems.filter { $0.need && (checks[$0.key]?.state ?? 0) == 0 }.map(\.title) }
    var checkDone: Int { siteCheckItems.filter { (checks[$0.key]?.state ?? 0) != 0 }.count }
}

struct ChecklistScreen: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(siteCheckItems, id: \.key) { it in
                        let st = store.site.checks[it.key]?.state ?? 0
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(it.title).font(.headline)
                                if it.need { Text("필수").font(.caption2.weight(.bold)).padding(.horizontal, 6).padding(.vertical, 2).background(Color(white: 0.92), in: Capsule()) }
                                Spacer()
                                Picker("", selection: Binding(get: { st }, set: { v in var c = store.site.checks[it.key] ?? SiteCheck(); c.state = v; store.site.checks[it.key] = c })) {
                                    Text("아직").tag(0); Text("확인").tag(1); Text("없음").tag(2)
                                }.pickerStyle(.segmented).frame(width: 170)
                            }
                            Text(it.hint).font(.caption).foregroundStyle(.secondary)
                            TextField("메모 (예: 욕실 배수 벽에서 350)", text: Binding(get: { store.site.checks[it.key]?.note ?? "" },
                                set: { v in var c = store.site.checks[it.key] ?? SiteCheck(); c.note = v; if c.state == 0 && !v.isEmpty { c.state = 1 }; store.site.checks[it.key] = c }))
                                .font(.subheadline)
                        }.padding(.vertical, 4)
                    }
                } footer: { Text("필수 항목이 비어 있으면 견적·보내기 전에 알려 드립니다. 하자는 사진 실측 메모로 찍어 두세요.") }
            }
            .navigationTitle("현장 확인 \(store.site.checkDone)/\(siteCheckItems.count)").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("닫기") { store.save(); dismiss() } } }
        }
    }
}
