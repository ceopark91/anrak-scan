import SwiftUI
import ARKit
import SceneKit

/// 카메라 자: 화면 가운데 십자를 맞추고 두 점을 찍으면 그 사이 길이(mm)
final class MeasureController: NSObject, ObservableObject {
    let view = ARSCNView(frame: .zero)
    @Published var points: [simd_float3] = []
    @Published var live: Int? = nil          // 첫 점 ~ 지금 가운데까지
    @Published var ready = false
    private var timer: Timer?
    private var nodes: [SCNNode] = []

    var distance: Int? {
        guard points.count == 2 else { return nil }
        return Int((simd_distance(points[0], points[1]) * 1000).rounded())
    }

    func start() {
        let c = ARWorldTrackingConfiguration()
        c.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) { c.sceneReconstruction = .mesh }
        view.session.run(c)
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
    }
    func stop() { timer?.invalidate(); view.session.pause() }

    private func hit() -> simd_float3? {
        let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        guard let q = view.raycastQuery(from: center, allowing: .estimatedPlane, alignment: .any),
              let r = view.session.raycast(q).first else { return nil }
        let t = r.worldTransform.columns.3
        return simd_float3(t.x, t.y, t.z)
    }
    private func tick() {
        let h = hit()
        ready = h != nil
        if points.count == 1, let h { live = Int((simd_distance(points[0], h) * 1000).rounded()) } else { live = nil }
    }
    func mark() {
        guard let h = hit() else { return }
        if points.count >= 2 { reset() }
        points.append(h)
        let n = SCNNode(geometry: SCNSphere(radius: 0.004))
        n.geometry?.firstMaterial?.diffuse.contents = UIColor.white
        n.simdPosition = h
        view.scene.rootNode.addChildNode(n); nodes.append(n)
        if points.count == 2 {
            let a = points[0], b = points[1]
            let len = simd_distance(a, b)
            let cyl = SCNNode(geometry: SCNCylinder(radius: 0.0015, height: CGFloat(len)))
            cyl.geometry?.firstMaterial?.diffuse.contents = UIColor.white
            cyl.simdPosition = (a + b) / 2
            let d = simd_normalize(b - a)
            cyl.simdOrientation = simd_quatf(from: simd_float3(0, 1, 0), to: d)
            view.scene.rootNode.addChildNode(cyl); nodes.append(cyl)
        }
    }
    func reset() { points = []; nodes.forEach { $0.removeFromParentNode() }; nodes = [] }
}

struct MeasureRepresentable: UIViewRepresentable {
    let c: MeasureController
    func makeUIView(context: Context) -> ARSCNView { c.view }
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

struct MeasureScreen: View {
    let title: String
    let onUse: (Int) -> Void
    @StateObject private var mc = MeasureController()
    @Environment(\.dismiss) var dismiss

    var body: some View {
        ZStack {
            MeasureRepresentable(c: mc).ignoresSafeArea()
            Image(systemName: "plus").font(.system(size: 30, weight: .light)).foregroundStyle(mc.ready ? .white : .red)
            VStack {
                HStack {
                    Button("닫기") { dismiss() }
                        .padding(.horizontal, 16).padding(.vertical, 10).background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 8).background(.black.opacity(0.55), in: Capsule())
                }
                .padding(.horizontal, 16).padding(.top, 8)
                Text(mc.points.isEmpty ? "가까이(30cm쯤) 대고 십자를 아래 끝에 맞춘 뒤 [점 찍기]" : mc.points.count == 1 ? "십자를 위 끝에 맞추고 한 번 더 [점 찍기]" : "맞으면 [적용], 아니면 [다시]")
                    .font(.footnote).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 7).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                Spacer()
                if let v = mc.distance ?? mc.live {
                    Text("\(mm(v)) mm").font(.system(size: 34, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 6).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                }
                HStack(spacing: 10) {
                    Button { mc.reset() } label: {
                        Text("다시").fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Color.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(.black)
                    }
                    if let d = mc.distance {
                        Button { onUse(d); dismiss() } label: {
                            Text("\(mm(d))mm 적용").fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 14)
                                .background(Color.black, in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(.white)
                        }
                    } else {
                        Button { mc.mark() } label: {
                            Text("점 찍기").fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 14)
                                .background(Color.black, in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(.white)
                        }
                    }
                }
                .padding(16)
            }
        }
        .onAppear { mc.start() }
        .onDisappear { mc.stop() }
    }
}
