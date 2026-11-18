import SwiftUI
import RoomPlan
import ARKit

/// 방을 여러 개 스캔해도 같은 AR 세션을 계속 써서 방끼리 위치가 맞게 한다.
final class CaptureController: NSObject, ObservableObject, RoomCaptureViewDelegate, RoomCaptureSessionDelegate {
    static let shared = CaptureController()

    let arSession = ARSession()
    lazy var view: RoomCaptureView = {
        let v = RoomCaptureView(frame: .zero, arSession: arSession)
        v.delegate = self
        v.captureSession.delegate = self
        return v
    }()
    let sessionId = uid()

    @Published var scanning = false
    @Published var processing = false
    @Published var result: CapturedRoom?
    @Published var marks: [(String, simd_float3)] = []   // 스캔 중 찍은 천장 기물 (세계 좌표)
    @Published var markMsg: String?

    /// 화면 가운데가 가리키는 곳(천장 등)의 세계 좌표
    func hitCenter() -> simd_float3? {
        guard let f = arSession.currentFrame else { return nil }
        let t = f.camera.transform
        let origin = simd_float3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let dir = -simd_normalize(simd_float3(t.columns.2.x, t.columns.2.y, t.columns.2.z))
        for target in [ARRaycastQuery.Target.existingPlaneGeometry, .estimatedPlane] {
            let q = ARRaycastQuery(origin: origin, direction: dir, allowing: target, alignment: .any)
            if let r = arSession.raycast(q).first {
                let p = r.worldTransform.columns.3
                return simd_float3(p.x, p.y, p.z)
            }
        }
        return nil
    }
    func mark(_ kind: String) {
        if let p = hitCenter() {
            marks.append((kind, p)); markMsg = "\(fixtureName(kind)) 표시함 (\(marks.count)개)"
        } else { markMsg = "천장을 못 찾았습니다. 조금 더 비춘 뒤 다시" }
    }
    @Published var error: String?
    @Published var hint = "천천히 방을 한 바퀴 돌며 벽·바닥·천장 모서리를 비춰 주세요"

    override init() { super.init() }
    required init?(coder: NSCoder) { super.init() }
    func encode(with coder: NSCoder) {}

    func start() {
        result = nil; error = nil; processing = false; scanning = true; marks = []; markMsg = nil; found = ""
        view.captureSession.run(configuration: RoomCaptureSession.Configuration())
    }
    func finish() {
        processing = true; scanning = false
        view.captureSession.stop(pauseARSession: false)   // 다음 방도 같은 좌표로
    }
    func cancel() {
        scanning = false; processing = false
        view.captureSession.stop(pauseARSession: false)
    }

    // RoomCaptureViewDelegate
    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool { true }
    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        DispatchQueue.main.async {
            self.processing = false
            if let error { self.error = "스캔 정리 실패: \(error.localizedDescription)" }
            self.result = processedResult
        }
    }

    @Published var found = ""
    /// 스캔 중 찾은 것 (벽·문·창·가구 개수)
    func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        let t = "벽 \(room.walls.count) · 문 \(room.doors.count + room.openings.count) · 창 \(room.windows.count) · 가구 \(room.objects.count)"
        DispatchQueue.main.async { self.found = t }
    }
    // RoomCaptureSessionDelegate: 화면 안내
    func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
        let t: String
        switch instruction {
        case .moveCloseToWall: t = "벽에 조금 더 가까이 가 주세요"
        case .moveAwayFromWall: t = "벽에서 조금 떨어져 주세요"
        case .slowDown: t = "조금 더 천천히 움직여 주세요"
        case .turnOnLight: t = "방이 어둡습니다. 불을 켜 주세요"
        case .lowTexture: t = "무늬가 없는 벽입니다. 모서리 쪽을 비춰 주세요"
        default: t = "천천히 방을 한 바퀴 돌며 벽·바닥·천장 모서리를 비춰 주세요"
        }
        DispatchQueue.main.async { self.hint = t }
    }
}

struct CaptureRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> RoomCaptureView { CaptureController.shared.view }
    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
}

struct CaptureScreen: View {
    @EnvironmentObject var store: Store
    @ObservedObject var cc = CaptureController.shared
    @Environment(\.dismiss) var dismiss
    @State private var name = "거실"
    @State private var saving = false
    @AppStorage("lastMold") private var mold = "none"
    @AppStorage("lastBase") private var base = 0
    @AppStorage("quickScan") private var quick = true   // 연속 스캔: 방 이름은 나중에
    @State private var endAll = false
    @State private var savedCount = 0
    @AppStorage("scanGuideSeen") private var guideSeen = false
    @State private var guide = false

    var body: some View {
        ZStack {
            CaptureRepresentable().ignoresSafeArea()
                .onAppear { if !guideSeen { guide = true } }
                .sheet(isPresented: $guide) { ScanGuide { guideSeen = true; guide = false } }
            if cc.scanning { Image(systemName: "plus").font(.system(size: 28, weight: .light)).foregroundStyle(.white).shadow(radius: 2) }
            VStack(spacing: 0) {
                HStack {
                    Button("취소") { cc.cancel(); dismiss() }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                    Button("요령") { guide = true }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                    if cc.scanning {
                        if quick {
                            Button("다음 방") { endAll = false; cc.finish() }
                                .fontWeight(.semibold)
                                .padding(.horizontal, 16).padding(.vertical, 10)
                                .background(Color.white, in: Capsule()).foregroundStyle(.black)
                            Button("전부 끝") { endAll = true; cc.finish() }
                                .fontWeight(.semibold)
                                .padding(.horizontal, 16).padding(.vertical, 10)
                                .background(Color.black, in: Capsule()).foregroundStyle(.white)
                        } else {
                            Button("다 찍었어요") { cc.finish() }
                                .fontWeight(.semibold)
                                .padding(.horizontal, 18).padding(.vertical, 10)
                                .background(Color.white, in: Capsule()).foregroundStyle(.black)
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.top, 8)
                if cc.scanning && savedCount == 0 && cc.marks.isEmpty {
                    Toggle("연속 스캔 (방 이름은 나중에)", isOn: $quick).font(.caption).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 40).padding(.top, 10)
                }
                if cc.scanning && savedCount > 0 {
                    Text("방 \(savedCount)개 저장됨 · 다음 방으로 걸어가며 계속 비추세요").font(.caption.weight(.semibold)).foregroundStyle(.black)
                        .padding(.horizontal, 12).padding(.vertical, 6).background(Color.white, in: Capsule()).padding(.top, 10)
                }
                if cc.scanning && !cc.found.isEmpty {
                    Text(cc.found).font(.caption.weight(.semibold)).foregroundStyle(.black)
                        .padding(.horizontal, 10).padding(.vertical, 5).background(Color.white.opacity(0.9), in: Capsule()).padding(.top, 8)
                }
                if cc.scanning {
                    Text(cc.hint).font(.subheadline).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
                        .padding(.top, 12)
                }
                Spacer()
                if cc.scanning {
                    VStack(spacing: 8) {
                        if let m = cc.markMsg { Text(m).font(.caption).foregroundStyle(.white).padding(6).background(.black.opacity(0.55), in: Capsule()) }
                        Text("천장 기물: 가운데 + 를 맞추고 누르기").font(.caption).foregroundStyle(.white)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(fixtureKinds, id: \.0) { k in
                                    Button(k.1) { cc.mark(k.0) }
                                        .font(.subheadline.weight(.semibold))
                                        .padding(.horizontal, 12).padding(.vertical, 9)
                                        .background(Color.white.opacity(0.92), in: Capsule()).foregroundStyle(.black)
                                }
                            }.padding(.horizontal, 12)
                        }
                    }
                    .padding(.bottom, 24)
                }
                if cc.processing {
                    ProgressView("도면으로 정리하는 중…").padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .padding(.bottom, 40)
                }
                if cc.result != nil && !quick { savePanel }
                if let e = cc.error { Text(e).foregroundStyle(.red).padding().background(.white) }
            }
        }
        .onAppear { savedCount = 0; cc.start() }
        .onChange(of: cc.result != nil) { _, has in
            guard has, quick else { return }
            name = "방 \(store.site.rooms.count + 1)"
            save(); savedCount += 1
            if endAll { dismiss() } else { cc.start() }
        }
        .navigationBarHidden(true)
    }

    var savePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("이 방 이름").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(roomTypes, id: \.self) { t in
                        Button(t) { name = t }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(name == t ? Color.black : Color(white: 0.93), in: Capsule())
                            .foregroundStyle(name == t ? .white : .black)
                    }
                }
            }
            FinishPicker(mold: $mold, base: $base)
            HStack(spacing: 10) {
                Button { save(); dismiss() } label: {
                    Text("저장").fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Color(white: 0.93), in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(.black)
                }
                Button { save(); name = "작은방"; cc.start() } label: {
                    Text("저장하고 다음 방").fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Color.black, in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(.white)
                }
            }
        }
        .padding(18)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 18))
        .padding(12)
        .disabled(saving)
    }

    func save() {
        guard let room = cc.result else { return }
        saving = true
        let fileName = "room_\(uid()).usdz"
        let url = Store.docs.appendingPathComponent(fileName)
        let ok = (try? room.export(to: url)) != nil
        if var r = RoomConverter.convert(room, name: name, sessionId: cc.sessionId, usdz: ok ? fileName : nil) {
            let rawName = "room_\(uid()).json"
            if let d = try? JSONEncoder().encode(room), (try? d.write(to: Store.docs.appendingPathComponent(rawName))) != nil { r.raw = rawName }
            r.moldType = mold; r.moldH = moldHeight(mold); r.baseH = base
            r.objs = Furn.objects(room, room: r)
            r.fixtures = cc.marks.map { m in
                let k = 1000 * LidarCal.scale
                let q = r.toLocal(CGPoint(x: Double(m.1.x) * k, y: Double(m.1.z) * k))
                return Fixture(id: uid(), kind: m.0, x: q.x.rounded(), y: q.y.rounded())
            }
            store.add(r)
        } else {
            cc.error = "벽을 3개 이상 찾지 못했습니다. 다시 스캔해 주세요"
        }
        cc.result = nil
        saving = false
    }
}


/// 라이다 스캔을 정확하게: 처음 한 번 보여 주는 안내 (스캔 화면 [요령]으로 다시 보기)
struct ScanGuide: View {
    let done: () -> Void
    let tips: [(String, String, String)] = [
        ("lightbulb", "불 다 켜기", "커튼·블라인드는 걷고, 어두우면 인식이 흔들립니다."),
        ("figure.walk", "벽을 따라 한 바퀴", "방 가운데가 아니라 벽에서 1~2m 떨어져 벽을 따라 돕니다."),
        ("tortoise", "천천히", "한 걸음에 1초. 폰은 가슴 높이로 들고 흔들지 않습니다."),
        ("arrow.up.and.down", "모서리는 위아래로", "모서리마다 천장 선과 바닥 선을 한 번씩 훑습니다."),
        ("rectangle.on.rectangle", "거울·유리는 비스듬히", "정면으로 비추면 반사 때문에 벽이 잘못 잡힙니다."),
        ("arrow.triangle.2.circlepath", "시작한 곳에서 끝내기", "출발점으로 돌아와 겹치게 비추고 끝내야 방이 딱 닫힙니다."),
        ("ruler", "긴 벽 하나만 재기", "끝난 뒤 가장 긴 벽 하나만 레이저·줄자로 재서 [도면 고치기]에 넣으면 나머지도 맞춰지고, 앱이 오차를 배워 다음 스캔이 더 정확해집니다.")]
    var body: some View {
        NavigationStack {
            List {
                ForEach(tips, id: \.1) { t in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: t.0).font(.title3).frame(width: 30)
                        VStack(alignment: .leading, spacing: 3) { Text(t.1).font(.headline); Text(t.2).font(.subheadline).foregroundStyle(.secondary) }
                    }.padding(.vertical, 4)
                }
                Section { Text("라이다 배율 보정: \(LidarCal.text) · 배운 값 \(LidarCal.learned)개").font(.caption).foregroundStyle(.secondary) }
            }
            .navigationTitle("정확하게 스캔하는 법").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("알겠어요") { done() }.fontWeight(.semibold) } }
        }
    }
}
