import SwiftUI
import ARKit
import Vision

// MARK: - 콘센트·스위치 찾기 (1단계: 반자동)
// 카메라 화면에서 작은 네모 판(가로세로 6~16cm쯤)을 Vision 네모 찾기로 후보로 보여 주고,
// 눌러서 콘센트/스위치로 정하면 바닥에서 높이(가운데)를 라이다로 잼. 후보가 없어도 화면을 누르면 그 자리로.

/// 벽에 붙은 것 종류 (아님은 배우기용)
let elecKinds: [(k: String, name: String, color: UIColor)] = [
    ("outlet", "콘센트", .systemOrange), ("switch", "스위치", .systemBlue), ("lan", "랜·TV 단자", .systemTeal),
    ("boiler", "보일러 조절기", .systemRed), ("wallpad", "월패드·인터폰", .systemPurple), ("etc", "기타", .systemGray)]
func elecName(_ k: String) -> String { k == "not" ? "아닌 것" : elecKinds.first { $0.k == k }?.name ?? "기타" }
func elecColor(_ k: String) -> Color { Color(elecKinds.first { $0.k == k }?.color ?? .systemGray) }

/// 방에 기록한 콘센트·스위치. h = 바닥에서 가운데까지(mm), n = 구 수
struct AElec: Codable, Hashable, Identifiable { var id = uid(); var k: String; var h: Int; var n: Int = 1 }

extension ScanRoom {
    var elecSummary: String {
        let e = elec ?? []
        guard !e.isEmpty else { return "" }
        func part(_ k: String, _ name: String) -> String? {
            let a = e.filter { $0.k == k }; guard !a.isEmpty else { return nil }
            let hs = a.map(\.h), lo = (hs.min() ?? 0) / 10, hi = (hs.max() ?? 0) / 10
            return "\(name) \(a.count)개(\(lo == hi ? "\(lo)" : "\(lo)~\(hi)")cm)"
        }
        return elecKinds.compactMap { part($0.k, $0.name) }.joined(separator: " · ")
    }
}

/// 화면 후보: rect 화면 좌표, norm = 카메라 영상 안 위치(0~1, 왼쪽 아래 기준), guess = 배운 것으로 짐작한 종류
struct ElecCand: Identifiable { var id = UUID(); var rect: CGRect; var norm: CGRect; var fp: VNFeaturePrintObservation?; var guess: String?; var conf: Double = 0 }

// MARK: 폰 안에서 배우기 (가까운 예 찾기)
// 사람이 [콘센트]/[스위치]/[아님]을 고를 때마다 그 부분의 Vision 특징값을 저장하고,
// 새 후보는 저장된 것 중 가장 비슷한 5개의 투표로 짐작. 한국 현장 것만 쌓이니 우리 현장에 맞게 좋아짐.
final class ElecLearn {
    static let shared = ElecLearn()
    struct Ex: Codable { var id: String; var k: String; var fp: Data }
    private(set) var ex: [Ex] = []
    private var obs: [String: VNFeaturePrintObservation] = [:]
    private var url: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("elec_learn.json") }
    init() {
        if let d = try? Data(contentsOf: url), let a = try? JSONDecoder().decode([Ex].self, from: d) { ex = a }
        for e in ex { if let o = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: e.fp) { obs[e.id] = o } }
    }
    func count(_ k: String) -> Int { ex.filter { $0.k == k }.count }
    func add(_ id: String, _ k: String, _ o: VNFeaturePrintObservation) {
        guard let d = try? NSKeyedArchiver.archivedData(withRootObject: o, requiringSecureCoding: true) else { return }
        ex.append(Ex(id: id, k: k, fp: d)); obs[id] = o; persist()
    }
    func remove(_ id: String) { ex.removeAll { $0.id == id }; obs[id] = nil; persist() }
    func reset() { ex = []; obs = [:]; persist() }
    private func persist() { if let d = try? JSONEncoder().encode(ex) { try? d.write(to: url) } }
    /// 짐작: (종류, 투표 비율). 배운 게 적으면 nil
    func guess(_ o: VNFeaturePrintObservation) -> (String, Double)? {
        guard ex.count >= 4 else { return nil }
        var ds: [(Float, String)] = []
        for e in ex { guard let r = obs[e.id] else { continue }; var d: Float = 0; if (try? o.computeDistance(&d, to: r)) != nil { ds.append((d, e.k)) } }
        ds.sort { $0.0 < $1.0 }
        let top = ds.prefix(5)
        guard !top.isEmpty else { return nil }
        var votes: [String: Double] = [:]
        for (d, k) in top { votes[k, default: 0] += 1 / Double(max(d, 0.05)) }
        let sum = votes.values.reduce(0, +)
        guard let best = votes.max(by: { $0.value < $1.value }) else { return nil }
        return (best.key, best.value / sum)
    }
    /// 영상 한 부분의 특징값
    static func feature(_ img: CVPixelBuffer, _ norm: CGRect) -> VNFeaturePrintObservation? {
        let pad = max(norm.width, norm.height) * 0.25
        let r = norm.insetBy(dx: -pad, dy: -pad).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard r.width > 0.005, r.height > 0.005 else { return nil }
        let rq = VNGenerateImageFeaturePrintRequest(); rq.regionOfInterest = r
        try? VNImageRequestHandler(cvPixelBuffer: img, orientation: .up).perform([rq])
        return rq.results?.first
    }
}

final class ElecController: NSObject, ObservableObject, ARSessionDelegate {
    let view = ARSCNView(frame: .zero)
    @Published var cands: [ElecCand] = []
    @Published var floorY: Float?
    private var busy = false, last = Date.distantPast
    private(set) var lastImg: CVPixelBuffer?
    private(set) var lastTf: CGAffineTransform = .identity

    func start() {
        let c = ARWorldTrackingConfiguration(); c.planeDetection = [.horizontal]
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) { c.frameSemantics = [.sceneDepth] }
        view.session.delegate = self
        view.automaticallyUpdatesLighting = true
        view.session.run(c)
    }
    func stop() { view.session.pause() }

    func session(_ s: ARSession, didAdd anchors: [ARAnchor]) { floor(anchors) }
    func session(_ s: ARSession, didUpdate anchors: [ARAnchor]) { floor(anchors) }
    private func floor(_ anchors: [ARAnchor]) {
        for case let a as ARPlaneAnchor in anchors where a.alignment == .horizontal {
            let y = a.transform.columns.3.y
            // 바닥 = 가장 낮은 수평면 (분류가 되면 바닥만)
            switch a.classification { case .floor, .none: break; default: continue }
            DispatchQueue.main.async { if self.floorY == nil || y < self.floorY! { self.floorY = y } }
        }
    }

    func session(_ s: ARSession, didUpdate frame: ARFrame) {
        guard !busy, Date().timeIntervalSince(last) > 0.4 else { return }
        busy = true; last = Date()
        let img = frame.capturedImage
        let size = view.bounds.size
        let tf = frame.displayTransform(for: .portrait, viewportSize: size)
        lastImg = img; lastTf = tf
        DispatchQueue.global(qos: .userInitiated).async {
            let rq = VNDetectRectanglesRequest()
            rq.minimumAspectRatio = 0.35; rq.maximumAspectRatio = 1.0
            rq.minimumSize = 0.04; rq.maximumObservations = 14; rq.quadratureTolerance = 18; rq.minimumConfidence = 0.6
            try? VNImageRequestHandler(cvPixelBuffer: img, orientation: .up).perform([rq])
            var out: [ElecCand] = []
            for o in rq.results ?? [] {
                let b = o.boundingBox                                         // 0~1, 왼쪽 아래 기준 (센서 가로 영상)
                let n = CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height).applying(tf)
                let r = CGRect(x: n.minX * size.width, y: n.minY * size.height, width: n.width * size.width, height: n.height * size.height).standardized
                guard r.width > 12, r.height > 12, r.width < size.width * 0.6 else { continue }
                var c = ElecCand(rect: r, norm: b)
                if ElecLearn.shared.ex.count >= 4, let fp = ElecLearn.feature(img, b) {
                    c.fp = fp
                    if let g = ElecLearn.shared.guess(fp) { c.guess = g.0; c.conf = g.1 }
                }
                out.append(c)
            }
            DispatchQueue.main.async {
                // 실제 크기로 거르기: 두 모서리를 벽에 쏴서 대각선 7~40cm (단자 작은 판 ~ 월패드)
                self.cands = out.filter { k in
                    let r = k.rect
                    guard let a = self.hit(CGPoint(x: r.minX, y: r.minY)), let b = self.hit(CGPoint(x: r.maxX, y: r.maxY)) else { return false }
                    let d = simd_distance(a, b)
                    // 배운 것으로 '아님'이 확실하면 숨김
                    return d > 0.06 && d < 0.40 && !(k.guess == "not" && k.conf > 0.7)
                }
                self.busy = false
            }
        }
    }

    /// 화면 점 → 3D 점 (벽면 추정)
    func hit(_ p: CGPoint) -> simd_float3? {
        guard let q = view.raycastQuery(from: p, allowing: .estimatedPlane, alignment: .any),
              let r = view.session.raycast(q).first else { return nil }
        let c = r.worldTransform.columns.3
        return simd_float3(c.x, c.y, c.z)
    }

    /// 화면 사각형 → 영상 위치(0~1, 왼쪽 아래 기준)
    func norm(_ r: CGRect) -> CGRect {
        let sz = view.bounds.size
        let v = CGRect(x: r.minX / sz.width, y: r.minY / sz.height, width: r.width / sz.width, height: r.height / sz.height)
        let n = v.applying(lastTf.inverted()).standardized
        return CGRect(x: n.minX, y: 1 - n.maxY, width: n.width, height: n.height)
    }

    /// 점을 콘센트/스위치로 표시하고 높이(mm) 돌려줌
    func place(_ p: CGPoint, kind: String) -> Int? {
        guard let w = hit(p), let fy = floorY else { return nil }
        let g = SCNSphere(radius: 0.015); g.firstMaterial?.diffuse.contents = elecKinds.first { $0.k == kind }?.color ?? .systemGray
        let n = SCNNode(geometry: g); n.simdPosition = w; view.scene.rootNode.addChildNode(n)
        return Int(((w.y - fy) * 1000 / 10).rounded()) * 10
    }
}

/// 한국 현장 학습용 사진: 정할 때마다 그 부분을 잘라 저장 (나중에 우리 현장 모델 학습)
enum ElecTrain {
    static var dir: URL { let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("elec_train"); try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true); return d }
    static var files: [URL] { ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "jpg" } }
    /// 화면 캡처에서 box(화면 좌표) 둘레를 넉넉히 잘라 저장. 파일 이름 = 종류_id_상자(잘린 사진 안 x,y,w,h 비율)
    static func save(_ shot: UIImage, box: CGRect, kind: String) {
        let sc = shot.scale
        let pad = max(box.width, box.height) * 1.2
        let crop = box.insetBy(dx: -pad, dy: -pad).intersection(CGRect(origin: .zero, size: shot.size))
        guard crop.width > 20, let cg = shot.cgImage?.cropping(to: CGRect(x: crop.minX * sc, y: crop.minY * sc, width: crop.width * sc, height: crop.height * sc)) else { return }
        let rx = (box.minX - crop.minX) / crop.width, ry = (box.minY - crop.minY) / crop.height
        let rw = box.width / crop.width, rh = box.height / crop.height
        let name = String(format: "%@_%@_%.3f_%.3f_%.3f_%.3f.jpg", kind, uid(), rx, ry, rw, rh)
        try? UIImage(cgImage: cg).jpegData(compressionQuality: 0.85)?.write(to: dir.appendingPathComponent(name))
    }
}

struct ElecRep: UIViewRepresentable {
    let c: ElecController
    func makeUIView(context: Context) -> ARSCNView { c.view }
    func updateUIView(_ v: ARSCNView, context: Context) {}
}

struct ElectricScreen: View {
    let roomId: String
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @StateObject private var c = ElecController()
    @State private var items: [AElec] = []
    @State private var pending: (rect: CGRect, at: CGPoint, norm: CGRect, guess: String?, conf: Double)?
    @State private var learned = ElecLearn.shared.ex.count
    @State private var gang = 2
    @State private var msg: String?
    @State private var trainCount = 0

    var body: some View {
        NavigationStack {
            ZStack {
                GeometryReader { _ in
                    ZStack(alignment: .topLeading) {
                        ElecRep(c: c)
                        ForEach(c.cands) { k in
                            let sure = k.conf > 0.7 && k.guess != nil && k.guess != "not"
                            RoundedRectangle(cornerRadius: 4).stroke(sure ? elecColor(k.guess!) : Color.yellow, lineWidth: 3)
                                .frame(width: k.rect.width, height: k.rect.height)
                                .overlay(alignment: .top) {
                                    if sure { Text(elecName(k.guess!)).font(.caption2.weight(.bold)).foregroundStyle(.white)
                                        .padding(.horizontal, 5).background(elecColor(k.guess!), in: Capsule()).fixedSize().offset(y: -18) }
                                }
                                .position(x: k.rect.midX, y: k.rect.midY)
                                .allowsHitTesting(false)
                        }
                        if let pd = pending {
                            RoundedRectangle(cornerRadius: 4).stroke(Color.white, style: StrokeStyle(lineWidth: 3, dash: [6, 4]))
                                .frame(width: pd.rect.width, height: pd.rect.height).position(x: pd.rect.midX, y: pd.rect.midY).allowsHitTesting(false)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { p in tap(p) }
                }
                .ignoresSafeArea()
                VStack { Spacer(); panel }
            }
            .navigationTitle("콘센트·스위치·단자").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("닫기") { c.stop(); dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button("저장") { save() }.fontWeight(.bold) }
                ToolbarItem(placement: .bottomBar) {
                    if trainCount > 0 { ShareLink(items: ElecTrain.files) { Text("학습용 사진 \(trainCount)장 내보내기").font(.caption) } }
                }
            }
            .onAppear { items = store.site.rooms.first { $0.id == roomId }?.elec ?? []; trainCount = ElecTrain.files.count; c.start() }
            .onDisappear { c.stop() }
        }
    }

    /// 누른 곳: 후보 안이면 그 후보, 아니면 누른 자리 → 아래에서 [콘센트][스위치][아님] 고르기
    func tap(_ p: CGPoint) {
        guard c.floorY != nil else { msg = "바닥을 먼저 한 번 비춰 주세요 (높이 기준)"; return }
        if let k = c.cands.first(where: { $0.rect.insetBy(dx: -20, dy: -20).contains(p) }) {
            pending = (k.rect, CGPoint(x: k.rect.midX, y: k.rect.midY), k.norm, k.guess, k.conf)
        } else {
            let r = CGRect(x: p.x - 30, y: p.y - 45, width: 60, height: 90)
            var g: (String, Double)? = nil
            if let img = c.lastImg, let fp = ElecLearn.feature(img, c.norm(r)) { g = ElecLearn.shared.guess(fp) }
            pending = (r, p, c.norm(r), g?.0, g?.1 ?? 0)
        }
    }

    /// 고름 = 기록 + 배우기
    func choose(_ kind: String) {
        guard let pd = pending else { return }
        pending = nil
        let id = uid()
        if let img = c.lastImg, let fp = ElecLearn.feature(img, pd.norm) { ElecLearn.shared.add(id, kind, fp); learned = ElecLearn.shared.ex.count }
        let shot = c.view.snapshot()
        ElecTrain.save(shot, box: pd.rect, kind: kind)
        trainCount = ElecTrain.files.count
        guard kind != "not" else { msg = "'아님'으로 배웠어요. 비슷한 건 다음부터 안 띄워요"; return }
        guard let h = c.place(pd.at, kind: kind) else { msg = "그 자리를 못 쟀어요. 조금 가까이(1m 안)에서 다시 눌러 주세요"; return }
        items.append(AElec(id: id, k: kind, h: h, n: kind == "outlet" ? gang : 1))
        msg = "\(elecName(kind)) 바닥에서 \(h / 10)cm"
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    var panel: some View {
        VStack(spacing: 10) {
            if let pd = pending {
                Text(pd.guess.map { g in pd.conf > 0.5 ? "\(elecName(g)) 같아요. 맞게 골라 주세요" : "이게 뭔가요?" } ?? "이게 뭔가요?")
                    .font(.subheadline.weight(.semibold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], spacing: 6) {
                    ForEach(elecKinds, id: \.k) { e in seg(e.name, e.k, pd.guess) }
                    seg("아님", "not", pd.guess)
                    Button("취소") { pending = nil }.font(.subheadline)
                }
                Stepper("콘센트면 \(gang)구", value: $gang, in: 1...4).font(.subheadline)
            } else {
                Text(c.floorY == nil ? "바닥을 한 번 비춘 뒤, 콘센트·스위치를 비추세요" : c.cands.isEmpty ? "콘센트·스위치를 비추면 네모가 떠요. 안 뜨면 그 자리를 그냥 누르세요" : "네모를 눌러 무엇인지 골라 주세요")
                    .font(.subheadline.weight(.semibold)).multilineTextAlignment(.center)
            }
            if let m = msg { Text(m).font(.caption).foregroundStyle(.secondary) }
            Text(learned < 4 ? "배우는 중: 몇 개만 골라 주면 그다음부터 알아서 짐작해요" : "배운 것 " + (elecKinds.map { ($0.name, ElecLearn.shared.count($0.k)) } + [("아님", ElecLearn.shared.count("not"))]).filter { $0.1 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " · "))
                .font(.caption2).foregroundStyle(.secondary)
            if !items.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(items) { e in
                            Button { items.removeAll { $0.id == e.id }; ElecLearn.shared.remove(e.id); learned = ElecLearn.shared.ex.count } label: {
                                Text("\(e.k == "outlet" ? "콘센트 \(e.n)구" : elecName(e.k)) \(e.h / 10)cm  ✕").font(.caption)
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(elecColor(e.k).opacity(0.2), in: Capsule())
                            }.foregroundStyle(.black)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(12)
    }

    func seg(_ t: String, _ k: String, _ guess: String?) -> some View {
        Button(t) { choose(k) }.font(.subheadline.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(guess == k ? Color.black : Color.white, in: Capsule()).foregroundStyle(guess == k ? .white : .black)
    }

    func save() {
        guard let i = store.site.rooms.firstIndex(where: { $0.id == roomId }) else { dismiss(); return }
        store.site.rooms[i].elec = items
        // 현장 확인 '콘센트·스위치 높이'에 자동으로 적기
        let lines = store.site.rooms.filter { !($0.elec ?? []).isEmpty }.map { "\($0.name): \($0.elecSummary)" }
        var ck = store.site.checks["elec"] ?? SiteCheck()
        if !lines.isEmpty { ck.state = 1; ck.note = lines.joined(separator: " / ") }
        store.site.checks["elec"] = ck
        // 견적 '스위치·콘센트' 개수
        var sel = store.site.est[store.site.rooms[i].id] ?? RoomSel()
        sel.outlets = max(sel.outlets, items.filter { $0.k == "outlet" || $0.k == "switch" }.count)
        store.site.est[store.site.rooms[i].id] = sel
        store.save()
        c.stop(); dismiss()
    }
}
