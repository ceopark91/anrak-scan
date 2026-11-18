import SwiftUI
import ARKit
import CoreImage

// MARK: - 벽 휨 지도 (참고용)
// 라이다 깊이(256×192)를 벽 평면에 맞추고, 평면에서 튀어나오거나 들어간 정도를 색으로.
// 라이다 깊이 오차가 ±5~10mm라 1m 안쪽에서만, 숫자는 참고용. (평면 찾기 끔 → 깊이만)

final class FlatController: NSObject, ObservableObject, ARSessionDelegate {
    let view = ARSCNView(frame: .zero)
    @Published var dist: Double = 0          // 화면 가운데까지 거리(m)
    @Published var result: UIImage?
    @Published var maxIn = 0.0
    @Published var maxOut = 0.0
    @Published var rms = 0.0
    @Published var area = 0.0
    @Published var busy = false
    private var last: ARFrame?
    private let ci = CIContext()

    func start() {
        guard ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) else { return }
        let c = ARWorldTrackingConfiguration(); c.frameSemantics = [.sceneDepth]
        view.session.delegate = self
        view.session.run(c)
    }
    func stop() { view.session.pause() }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        last = frame
        guard let d = frame.sceneDepth?.depthMap else { return }
        CVPixelBufferLockBaseAddress(d, .readOnly); defer { CVPixelBufferUnlockBaseAddress(d, .readOnly) }
        let w = CVPixelBufferGetWidth(d), h = CVPixelBufferGetHeight(d), rb = CVPixelBufferGetBytesPerRow(d) / 4
        guard let p = CVPixelBufferGetBaseAddress(d)?.assumingMemoryBound(to: Float32.self) else { return }
        let z = Double(p[(h / 2) * rb + w / 2])
        DispatchQueue.main.async { if abs(self.dist - z) > 0.01 { self.dist = z } }
    }

    /// 지금 화면으로 휨 지도 만들기
    func capture() {
        guard let f = last, let dm = f.sceneDepth?.depthMap else { return }
        busy = true
        let conf = f.sceneDepth?.confidenceMap
        let K = f.camera.intrinsics, img = f.capturedImage
        DispatchQueue.global(qos: .userInitiated).async {
            let out = Self.compute(dm, conf, K, CGSize(width: CVPixelBufferGetWidth(img), height: CVPixelBufferGetHeight(img)))
            var photo: CGImage? = nil
            let ciImg = CIImage(cvPixelBuffer: img)
            let sx = CGFloat(out.w) / ciImg.extent.width
            photo = self.ci.createCGImage(ciImg.transformed(by: CGAffineTransform(scaleX: sx, y: sx)), from: CGRect(x: 0, y: 0, width: out.w, height: out.h))
            let merged = Self.blend(photo, out)
            DispatchQueue.main.async {
                self.result = merged; self.maxIn = out.minD; self.maxOut = out.maxD; self.rms = out.rms; self.area = out.area; self.busy = false
            }
        }
    }

    struct Out { var w: Int; var h: Int; var dev: [Float]; var ok: [Bool]; var minD: Double; var maxD: Double; var rms: Double; var area: Double }

    static func compute(_ dm: CVPixelBuffer, _ cm: CVPixelBuffer?, _ K: simd_float3x3, _ imgSize: CGSize) -> Out {
        CVPixelBufferLockBaseAddress(dm, .readOnly); defer { CVPixelBufferUnlockBaseAddress(dm, .readOnly) }
        if let cm { CVPixelBufferLockBaseAddress(cm, .readOnly) }
        defer { if let cm { CVPixelBufferUnlockBaseAddress(cm, .readOnly) } }
        let w = CVPixelBufferGetWidth(dm), h = CVPixelBufferGetHeight(dm), rb = CVPixelBufferGetBytesPerRow(dm) / 4
        let dp = CVPixelBufferGetBaseAddress(dm)!.assumingMemoryBound(to: Float32.self)
        let cp = cm.flatMap { CVPixelBufferGetBaseAddress($0)?.assumingMemoryBound(to: UInt8.self) }
        let crb = cm.map { CVPixelBufferGetBytesPerRow($0) } ?? 0
        let s = Float(w) / Float(imgSize.width)
        let fx = K[0][0] * s, fy = K[1][1] * s, cx = K[2][0] * s, cy = K[2][1] * s
        var X = [Float](repeating: 0, count: w * h), Y = X, Z = X
        var ok = [Bool](repeating: false, count: w * h)
        for v in 0..<h { for u in 0..<w {
            let z = dp[v * rb + u]
            let good = z > 0.15 && z < 1.6 && (cp == nil || cp![v * crb + u] >= 1)
            guard good else { continue }
            let i = v * w + u
            X[i] = (Float(u) - cx) * z / fx; Y[i] = (Float(v) - cy) * z / fy; Z[i] = z; ok[i] = true
        } }
        // 평면 z = a·x + b·y + c (가운데 60%로 맞추고, 2번 다시 맞추며 튀는 점 뺌)
        var use = ok
        for v in 0..<h { for u in 0..<w where u < w / 5 || u > w * 4 / 5 || v < h / 5 || v > h * 4 / 5 { use[v * w + u] = false } }
        var a: Float = 0, b: Float = 0, c: Float = 0
        for pass in 0..<3 {
            var sxx: Float = 0, sxy: Float = 0, syy: Float = 0, sx: Float = 0, sy: Float = 0, n: Float = 0, sxz: Float = 0, syz: Float = 0, sz: Float = 0
            for i in 0..<(w * h) where use[i] {
                let x = X[i], y = Y[i], z = Z[i]
                sxx += x * x; sxy += x * y; syy += y * y; sx += x; sy += y; n += 1; sxz += x * z; syz += y * z; sz += z
            }
            guard n > 100 else { break }
            let M = simd_float3x3(simd_float3(sxx, sxy, sx), simd_float3(sxy, syy, sy), simd_float3(sx, sy, n))
            guard abs(M.determinant) > 1e-12 else { break }
            let r = M.inverse * simd_float3(sxz, syz, sz)
            a = r.x; b = r.y; c = r.z
            if pass < 2 {
                let lim: Float = pass == 0 ? 0.03 : 0.015
                for i in 0..<(w * h) where use[i] { if abs(Z[i] - (a * X[i] + b * Y[i] + c)) > lim { use[i] = false } }
            }
        }
        let norm = sqrt(a * a + b * b + 1)
        var dev = [Float](repeating: 0, count: w * h)
        var mn = 0.0, mx = 0.0, ss = 0.0, cnt = 0.0, ar = 0.0
        for i in 0..<(w * h) where ok[i] {
            // 평면까지 거리(mm), + = 카메라 쪽으로 튀어나옴
            let d = (a * X[i] + b * Y[i] + c - Z[i]) / norm * 1000
            dev[i] = d
            if abs(d) < 40 {
                mn = min(mn, Double(d)); mx = max(mx, Double(d)); ss += Double(d * d); cnt += 1
                ar += Double(Z[i] * Z[i] / (fx * fy))
            } else { ok[i] = false }      // 벽이 아닌 것(가구·모서리 너머)
        }
        return Out(w: w, h: h, dev: dev, ok: ok, minD: mn, maxD: mx, rms: cnt > 0 ? (ss / cnt).squareRoot() : 0, area: ar)
    }

    /// 색: 초록 = ±2mm, 노랑 = 2~5mm, 빨강 = 튀어나옴 5mm+, 파랑 = 들어감 5mm+
    static func blend(_ photo: CGImage?, _ o: Out) -> UIImage? {
        var px = [UInt8](repeating: 0, count: o.w * o.h * 4)
        for i in 0..<(o.w * o.h) {
            guard o.ok[i] else { continue }
            let d = o.dev[i], ad = abs(d)
            let col: (UInt8, UInt8, UInt8) = ad < 2 ? (70, 170, 90) : ad < 5 ? (230, 190, 60) : d > 0 ? (215, 70, 60) : (60, 110, 210)
            px[i * 4] = col.0; px[i * 4 + 1] = col.1; px[i * 4 + 2] = col.2; px[i * 4 + 3] = 140
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: o.w, height: o.h, bitsPerComponent: 8, bytesPerRow: o.w * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if let photo { ctx.draw(photo, in: CGRect(x: 0, y: 0, width: o.w, height: o.h)) }
        guard let pr = CGDataProvider(data: Data(px) as CFData),
              let ov = CGImage(width: o.w, height: o.h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: o.w * 4, space: cs,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: pr, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        ctx.draw(ov, in: CGRect(x: 0, y: 0, width: o.w, height: o.h))
        guard let cg = ctx.makeImage() else { return nil }
        return UIImage(cgImage: cg, scale: 1, orientation: .right)      // 깊이는 가로 → 세로 화면
    }
}

struct FlatRep: UIViewRepresentable {
    let c: FlatController
    func makeUIView(context: Context) -> ARSCNView { c.view }
    func updateUIView(_ v: ARSCNView, context: Context) {}
}

struct FlatnessScreen: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var c = FlatController()

    var body: some View {
        NavigationStack {
            ZStack {
                if let img = c.result {
                    Color.black.ignoresSafeArea()
                    Image(uiImage: img).interpolation(.none).resizable().scaledToFit()
                } else {
                    FlatRep(c: c).ignoresSafeArea()
                    Image(systemName: "plus").font(.title).foregroundStyle(.white)
                }
                VStack {
                    Spacer()
                    panel
                }
            }
            .navigationTitle("벽 휨 보기 (참고용)").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("닫기") { c.stop(); dismiss() } } }
            .onAppear { c.start() }
            .onDisappear { c.stop() }
        }
    }

    var panel: some View {
        VStack(spacing: 10) {
            if c.result != nil {
                Text(String(format: "튀어나옴 최대 %.0fmm · 들어감 최대 %.0fmm · 평균 %.1fmm", c.maxOut, -c.maxIn, c.rms)).font(.subheadline.weight(.semibold))
                Text(String(format: "본 넓이 약 %.1f㎡ · 라이다 오차가 몇 mm라 참고만, 퍼티·평탄 작업 판단은 직선자로 확인", c.area)).font(.caption).foregroundStyle(.secondary)
                legend
                Button { c.result = nil } label: { Text("다시 보기").fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 13) }
                    .background(Color.black, in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(.white)
            } else {
                let near = c.dist > 0.3 && c.dist < 1.2
                Text(c.dist > 0 ? String(format: "벽까지 %.2fm  %@", c.dist, near ? "좋아요" : c.dist >= 1.2 ? "· 더 가까이 (1m 안)" : "· 조금 뒤로") : "벽을 정면으로 비추세요")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(near ? .green : .orange)
                Text("벽과 나란하게, 50~100cm 떨어져서 가만히 들고 누르세요").font(.caption).foregroundStyle(.secondary)
                Button { c.capture() } label: { Text(c.busy ? "계산 중…" : "휨 보기").fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 13) }
                    .background(near ? Color.black : Color.gray, in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(.white)
                    .disabled(c.busy || c.dist <= 0)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(12)
    }

    var legend: some View {
        HStack(spacing: 10) {
            dot(Color(red: 0.27, green: 0.67, blue: 0.35), "±2mm"); dot(Color(red: 0.9, green: 0.75, blue: 0.24), "2~5mm")
            dot(Color(red: 0.84, green: 0.27, blue: 0.24), "튀어나옴 5+"); dot(Color(red: 0.24, green: 0.43, blue: 0.82), "들어감 5+")
        }.font(.caption2)
    }
    func dot(_ c: Color, _ t: String) -> some View { HStack(spacing: 3) { Circle().fill(c).frame(width: 9, height: 9); Text(t) } }
}
