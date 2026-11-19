import SwiftUI
import ARKit
import Vision

// MARK: - 콘센트·스위치 찾기 (1단계: 반자동)
// 카메라 화면에서 작은 네모 판(가로세로 6~16cm쯤)을 Vision 네모 찾기로 후보로 보여 주고,
// 눌러서 콘센트/스위치로 정하면 바닥에서 높이(가운데)를 라이다로 잼. 후보가 없어도 화면을 누르면 그 자리로.

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
        return [part("outlet", "콘센트"), part("switch", "스위치")].compactMap { $0 }.joined(separator: " · ")
    }
}

struct ElecCand: Identifiable, Equatable { var id = UUID(); var rect: CGRect }        // 화면 좌표

final class ElecController: NSObject, ObservableObject, ARSessionDelegate {
    let view = ARSCNView(frame: .zero)
    @Published var cands: [ElecCand] = []
    @Published var floorY: Float?
    private var busy = false, last = Date.distantPast

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
        DispatchQueue.global(qos: .userInitiated).async {
            let rq = VNDetectRectanglesRequest()
            rq.minimumAspectRatio = 0.35; rq.maximumAspectRatio = 1.0
            rq.minimumSize = 0.04; rq.maximumObservations = 10; rq.quadratureTolerance = 18; rq.minimumConfidence = 0.6
            try? VNImageRequestHandler(cvPixelBuffer: img, orientation: .up).perform([rq])
            var out: [CGRect] = []
            for o in rq.results ?? [] {
                let b = o.boundingBox                                         // 0~1, 왼쪽 아래 기준 (센서 가로 영상)
                let n = CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height).applying(tf)
                let r = CGRect(x: n.minX * size.width, y: n.minY * size.height, width: n.width * size.width, height: n.height * size.height).standardized
                if r.width > 12, r.height > 12, r.width < size.width * 0.6 { out.append(r) }
            }
            DispatchQueue.main.async {
                // 실제 크기로 거르기: 두 모서리를 벽에 쏴서 대각선 8~22cm
                self.cands = out.compactMap { r in
                    guard let a = self.hit(CGPoint(x: r.minX, y: r.minY)), let b = self.hit(CGPoint(x: r.maxX, y: r.maxY)) else { return nil }
                    let d = simd_distance(a, b)
                    return d > 0.07 && d < 0.23 ? ElecCand(rect: r) : nil
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

    /// 점을 콘센트/스위치로 표시하고 높이(mm) 돌려줌
    func place(_ p: CGPoint, kind: String) -> Int? {
        guard let w = hit(p), let fy = floorY else { return nil }
        let g = SCNSphere(radius: 0.015); g.firstMaterial?.diffuse.contents = kind == "outlet" ? UIColor.systemOrange : UIColor.systemBlue
        let n = SCNNode(geometry: g); n.simdPosition = w; view.scene.rootNode.addChildNode(n)
        return Int(((w.y - fy) * 1000 / 10).rounded()) * 10
    }
}

/// 한국 현장 학습용 사진: 정할 때마다 그 부분을 잘라 저장 (나중에 우리 현장 모델 학습)
enum ElecTrain {
    static var dir: URL { let d = Store.docs.appendingPathComponent("elec_train"); try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true); return d }
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
    @State private var kind = "outlet"
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
                            RoundedRectangle(cornerRadius: 4).stroke(Color.yellow, lineWidth: 3)
                                .frame(width: k.rect.width, height: k.rect.height)
                                .position(x: k.rect.midX, y: k.rect.midY)
                                .allowsHitTesting(false)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { p in tap(p) }
                }
                .ignoresSafeArea()
                VStack { Spacer(); panel }
            }
            .navigationTitle("콘센트·스위치").navigationBarTitleDisplayMode(.inline)
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

    /// 누른 곳: 노란 후보 안이면 그 가운데, 아니면 누른 자리
    func tap(_ p: CGPoint) {
        let hitBox = c.cands.first { $0.rect.insetBy(dx: -20, dy: -20).contains(p) }?.rect
        let at = hitBox.map { CGPoint(x: $0.midX, y: $0.midY) } ?? p
        guard c.floorY != nil else { msg = "바닥을 먼저 한 번 비춰 주세요 (높이 기준)"; return }
        guard let h = c.place(at, kind: kind) else { msg = "그 자리를 못 쟀어요. 조금 가까이(1m 안)에서 다시 눌러 주세요"; return }
        items.append(AElec(k: kind, h: h, n: kind == "outlet" ? gang : 1))
        let shot = c.view.snapshot()
        ElecTrain.save(shot, box: hitBox ?? CGRect(x: p.x - 40, y: p.y - 60, width: 80, height: 120), kind: kind)
        trainCount = ElecTrain.files.count
        msg = "\(kind == "outlet" ? "콘센트" : "스위치") 바닥에서 \(h / 10)cm"
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    var panel: some View {
        VStack(spacing: 10) {
            Text(c.floorY == nil ? "바닥을 한 번 비춘 뒤, 콘센트·스위치를 비추세요" : c.cands.isEmpty ? "콘센트·스위치를 비추면 노란 네모가 떠요. 없으면 그 자리를 그냥 누르세요" : "노란 네모를 누르면 기록돼요")
                .font(.subheadline.weight(.semibold)).multilineTextAlignment(.center)
            if let m = msg { Text(m).font(.caption).foregroundStyle(.secondary) }
            HStack(spacing: 8) {
                seg("콘센트", "outlet"); seg("스위치", "switch")
                if kind == "outlet" {
                    Stepper("\(gang)구", value: $gang, in: 1...4).font(.subheadline).fixedSize()
                }
            }
            if !items.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(items) { e in
                            Button { items.removeAll { $0.id == e.id } } label: {
                                Text("\(e.k == "outlet" ? "콘센트 \(e.n)구" : "스위치") \(e.h / 10)cm  ✕").font(.caption)
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(e.k == "outlet" ? Color.orange.opacity(0.2) : Color.blue.opacity(0.18), in: Capsule())
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

    func seg(_ t: String, _ k: String) -> some View {
        Button(t) { kind = k }.font(.subheadline.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 8)
            .background(kind == k ? Color.black : Color.white, in: Capsule()).foregroundStyle(kind == k ? .white : .black)
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
        sel.outlets = max(sel.outlets, items.count)
        store.site.est[store.site.rooms[i].id] = sel
        store.save()
        c.stop(); dismiss()
    }
}
