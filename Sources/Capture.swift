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
    @Published var error: String?
    @Published var hint = "천천히 방을 한 바퀴 돌며 벽·바닥·천장 모서리를 비춰 주세요"

    override init() { super.init() }
    required init?(coder: NSCoder) { super.init() }
    func encode(with coder: NSCoder) {}

    func start() {
        result = nil; error = nil; processing = false; scanning = true
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

    var body: some View {
        ZStack {
            CaptureRepresentable().ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button("취소") { cc.cancel(); dismiss() }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                    if cc.scanning {
                        Button("다 찍었어요") { cc.finish() }
                            .fontWeight(.semibold)
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background(Color.white, in: Capsule()).foregroundStyle(.black)
                    }
                }
                .padding(.horizontal, 16).padding(.top, 8)
                if cc.scanning {
                    Text(cc.hint).font(.subheadline).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
                        .padding(.top, 12)
                }
                Spacer()
                if cc.processing {
                    ProgressView("도면으로 정리하는 중…").padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .padding(.bottom, 40)
                }
                if cc.result != nil { savePanel }
                if let e = cc.error { Text(e).foregroundStyle(.red).padding().background(.white) }
            }
        }
        .onAppear { cc.start() }
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
            store.add(r)
        } else {
            cc.error = "벽을 3개 이상 찾지 못했습니다. 다시 스캔해 주세요"
        }
        cc.result = nil
        saving = false
    }
}
