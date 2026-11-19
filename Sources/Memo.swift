import SwiftUI
import ARKit
import PhotosUI
import Vision

// MARK: - 사진 실측 메모: 사진 위에 점과 점으로 선을 긋고 치수를 적는다.
// 아이폰 라이다로 찍으면 사진 깊이 정보로 선 길이를 먼저 대략 계산해 준다.

struct MemoLine: Codable, Identifiable, Hashable {
    var id = uid()
    var ax: Double, ay: Double, bx: Double, by: Double   // 사진 안 위치(0~1)
    var mm: Int? = nil       // 확정 치수(직접 입력·레이저)
    var auto: Int? = nil     // 라이다로 계산한 대략 치수
    var label = ""
}

struct MeasureMemo: Codable, Identifiable {
    var id = uid()
    var title = ""
    var photo: String
    var depth: String? = nil
    var lines: [MemoLine] = []
    var date = Date()
}

/// 라이다 깊이 + 카메라 정보 (사진 한 장분)
struct MemoDepth: Codable {
    var w: Int, h: Int               // 깊이 지도 크기 (센서 방향)
    var imgW: Double, imgH: Double   // 센서 사진 크기 (가로가 김)
    var fx: Double, fy: Double, cx: Double, cy: Double
    var data: Data                   // Float32 m

    /// 세로 사진 위 위치(0~1) → 카메라 기준 3D 점 (m)
    func point(_ nx: Double, _ ny: Double) -> simd_double3? {
        // 세로 사진은 센서 사진을 시계 방향으로 90° 돌린 것
        let u = ny * imgW, v = imgH - nx * imgH
        let du = Int(u / imgW * Double(w)), dv = Int(v / imgH * Double(h))
        var vals: [Float] = []
        data.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
            let f = b.bindMemory(to: Float.self)
            for y in max(0, dv - 1)...min(h - 1, dv + 1) {
                for x in max(0, du - 1)...min(w - 1, du + 1) {
                    let d = f[y * w + x]; if d.isFinite && d > 0.05 { vals.append(d) }
                }
            }
        }
        guard !vals.isEmpty else { return nil }
        let d = Double(vals.sorted()[vals.count / 2])
        return simd_double3((u - cx) * d / fx, (v - cy) * d / fy, d)
    }
    func length(_ l: MemoLine) -> Int? {
        guard let a = point(l.ax, l.ay), let b = point(l.bx, l.by) else { return nil }
        return Int((simd_distance(a, b) * 1000 * LidarCal.scale / 5).rounded()) * 5
    }
}

// MARK: 끝점 보정 (사진 분석: 모서리 → 없으면 가장 뚜렷한 경계선)

final class EdgeSnapper {
    let w: Int, h: Int
    private var g: [Float]

    init?(_ img: UIImage, maxSide: Int = 1000) {
        guard let cg = img.cgImage else { return nil }
        let s = min(1, Double(maxSide) / Double(max(cg.width, cg.height)))
        w = max(1, Int(Double(cg.width) * s)); h = max(1, Int(Double(cg.height) * s))
        var px = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        g = px.map { Float($0) / 255 }
    }

    private func grad(_ x: Int, _ y: Int) -> (Float, Float) {
        let xl = max(0, x - 1), xr = min(w - 1, x + 1), yu = max(0, y - 1), yd = min(h - 1, y + 1)
        return (g[y * w + xr] - g[y * w + xl], g[yd * w + x] - g[yu * w + x])
    }

    /// (0~1) 위치를 근처 모서리나 경계선으로 옮김. radius는 사진 짧은 변 대비 비율
    func snap(_ nx: Double, _ ny: Double, radius: Double = 0.03) -> (Double, Double) {
        let cx = Int(nx * Double(w)), cy = Int(ny * Double(h))
        let r = max(6, Int(radius * Double(min(w, h))))
        let x0 = max(2, cx - r), x1 = min(w - 3, cx + r), y0 = max(2, cy - r), y1 = min(h - 3, cy + r)
        guard x0 < x1, y0 < y1 else { return (nx, ny) }
        // 기울기 미리 계산
        let bw = x1 - x0 + 5, bh = y1 - y0 + 5
        var ix = [Float](repeating: 0, count: bw * bh), iy = ix
        for y in 0..<bh { for x in 0..<bw {
            let (a, b) = grad(min(w - 1, max(0, x0 - 2 + x)), min(h - 1, max(0, y0 - 2 + y)))
            ix[y * bw + x] = a; iy[y * bw + x] = b
        } }
        var bestC: (Float, Int, Int) = (0, cx, cy), bestE: (Float, Int, Int) = (0, cx, cy)
        for y in y0...y1 { for x in x0...x1 {
            var a: Float = 0, b: Float = 0, c: Float = 0
            for dy in -2...2 { for dx in -2...2 {
                let k = (y - y0 + 2 + dy) * bw + (x - x0 + 2 + dx)
                a += ix[k] * ix[k]; b += ix[k] * iy[k]; c += iy[k] * iy[k]
            } }
            let minEig = (a + c) / 2 - ((a - c) * (a - c) / 4 + b * b).squareRoot()
            // 가까운 곳을 조금 더 우선
            let dist = Float(hypot(Double(x - cx), Double(y - cy)) / Double(r))
            let wgt = 1 - 0.35 * dist
            if minEig * wgt > bestC.0 { bestC = (minEig * wgt, x, y) }
            let k = (y - y0 + 2) * bw + (x - x0 + 2)
            let mag = (ix[k] * ix[k] + iy[k] * iy[k]) * wgt
            if mag > bestE.0 { bestE = (mag, x, y) }
        } }
        // 모서리가 충분히 뚜렷하면 모서리, 아니면 경계선, 둘 다 약하면 그대로
        let p: (Int, Int)
        if bestC.0 > 0.02 { p = (bestC.1, bestC.2) }
        else if bestE.0 > 0.004 { p = (bestE.1, bestE.2) }
        else { return (nx, ny) }
        return ((Double(p.0) + 0.5) / Double(w), (Double(p.1) + 0.5) / Double(h))
    }
}

// MARK: 사진 속 곧은 선 자동 찾기 (Vision 윤곽 → 다각형 근사 → 긴 변만 → 같은 선끼리 합치기)

struct AutoSeg: Hashable { var a: CGPoint; var b: CGPoint      // 사진 위치 0~1 (위가 0)
    var len: Double { hypot(b.x - a.x, b.y - a.y) }
    var ang: Double { atan2(b.y - a.y, b.x - a.x) }
    func near(_ p: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y, L2 = max(1e-9, dx * dx + dy * dy)
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / L2)); return CGPoint(x: a.x + dx * t, y: a.y + dy * t)
    }
    /// 무한 직선 위로 내린 점
    func proj(_ p: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y, L2 = max(1e-9, dx * dx + dy * dy)
        let t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / L2; return CGPoint(x: a.x + dx * t, y: a.y + dy * t)
    }
}

enum LineFinder {
    static func find(_ img: UIImage) -> [AutoSeg] {
        guard let cg = img.cgImage else { return [] }
        let req = VNDetectContoursRequest()
        req.contrastAdjustment = 2.0; req.maximumImageDimension = 1024; req.detectsDarkOnLight = true
        let h = VNImageRequestHandler(cgImage: cg, orientation: cgOrient(img.imageOrientation))
        try? h.perform([req])
        guard let obs = req.results?.first else { return [] }
        var segs: [AutoSeg] = []
        func walk(_ c: VNContour) {
            if let poly = try? c.polygonApproximation(epsilon: 0.004) {
                let pts = poly.normalizedPoints.map { CGPoint(x: Double($0.x), y: 1 - Double($0.y)) }
                if pts.count >= 2 { for i in 0..<(pts.count - 1) {
                    let s = AutoSeg(a: pts[i], b: pts[i + 1]); if s.len > 0.06 { segs.append(s) } } }
            }
            for k in c.childContours { walk(k) }
        }
        for c in obs.topLevelContours { walk(c) }
        // 같은 직선(각도 3° · 거리 0.008 안)이면 하나로
        segs.sort { $0.len > $1.len }
        var out: [AutoSeg] = []
        for s in segs {
            var merged = false
            for k in out.indices {
                let o = out[k]
                var d = abs(s.ang - o.ang).truncatingRemainder(dividingBy: .pi); d = min(d, .pi - d)
                guard d < 3 * .pi / 180 else { continue }
                let pa = o.proj(s.a), pb = o.proj(s.b)
                guard hypot(pa.x - s.a.x, pa.y - s.a.y) < 0.008, hypot(pb.x - s.b.x, pb.y - s.b.y) < 0.008 else { continue }
                // 직선 방향으로 가장 먼 두 점
                let all = [o.a, o.b, s.a, s.b], u = CGPoint(x: cos(o.ang), y: sin(o.ang))
                let tt = all.map { $0.x * u.x + $0.y * u.y }
                let lo = all[tt.firstIndex(of: tt.min()!)!], hi = all[tt.firstIndex(of: tt.max()!)!]
                if hypot(hi.x - lo.x, hi.y - lo.y) <= o.len + s.len + 0.03 { out[k] = AutoSeg(a: o.proj(lo), b: o.proj(hi)) }
                merged = true; break
            }
            if !merged { out.append(s) }
        }
        return Array(out.sorted { $0.len > $1.len }.prefix(40))
    }
    static func cgOrient(_ o: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch o { case .right: return .right; case .left: return .left; case .down: return .down
        case .upMirrored: return .upMirrored; case .downMirrored: return .downMirrored; case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored; default: return .up }
    }
}

// MARK: 라이다 사진 찍기

@MainActor
final class MemoCamera: NSObject, ObservableObject {
    let view = ARSCNView(frame: .zero)
    var hasDepth: Bool { ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) }

    func start() {
        let c = ARWorldTrackingConfiguration()
        if hasDepth { c.frameSemantics.insert(.smoothedSceneDepth) }
        view.session.run(c)
    }
    func stop() { view.session.pause() }

    /// 지금 화면을 사진 + 깊이로 저장 → (사진 파일, 깊이 파일)
    func shoot() -> (String, String?)? {
        guard let f = view.session.currentFrame else { return nil }
        let ci = CIImage(cvPixelBuffer: f.capturedImage).oriented(.right)
        guard let cg = CIContext().createCGImage(ci, from: ci.extent),
              let jpg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.85) else { return nil }
        let photo = "memo_\(uid()).jpg"
        try? jpg.write(to: Store.docs.appendingPathComponent(photo))
        var depthName: String? = nil
        if let dm = (f.smoothedSceneDepth ?? f.sceneDepth)?.depthMap {
            CVPixelBufferLockBaseAddress(dm, .readOnly)
            let w = CVPixelBufferGetWidth(dm), h = CVPixelBufferGetHeight(dm), row = CVPixelBufferGetBytesPerRow(dm)
            var data = Data(capacity: w * h * 4)
            if let base = CVPixelBufferGetBaseAddress(dm) {
                for y in 0..<h { data.append(Data(bytes: base + y * row, count: w * 4)) }
            }
            CVPixelBufferUnlockBaseAddress(dm, .readOnly)
            let k = f.camera.intrinsics, res = f.camera.imageResolution
            let md = MemoDepth(w: w, h: h, imgW: Double(res.width), imgH: Double(res.height),
                               fx: Double(k[0][0]), fy: Double(k[1][1]), cx: Double(k[2][0]), cy: Double(k[2][1]), data: data)
            if let d = try? JSONEncoder().encode(md) {
                let n = "memo_\(uid()).depth"
                if (try? d.write(to: Store.docs.appendingPathComponent(n))) != nil { depthName = n }
            }
        }
        return (photo, depthName)
    }
}

struct MemoCameraRep: UIViewRepresentable {
    let cam: MemoCamera
    func makeUIView(context: Context) -> ARSCNView { cam.view }
    func updateUIView(_ v: ARSCNView, context: Context) {}
}

struct MemoCameraScreen: View {
    @StateObject private var cam = MemoCamera()
    @Environment(\.dismiss) var dismiss
    var onShot: (String, String?) -> Void

    var body: some View {
        ZStack {
            MemoCameraRep(cam: cam).ignoresSafeArea()
            VStack {
                HStack {
                    Button("취소") { dismiss() }
                        .padding(.horizontal, 16).padding(.vertical, 10).background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                }.padding(16)
                Text(cam.hasDepth ? "잴 곳이 다 보이게 찍으세요 (라이다로 길이를 먼저 계산합니다)" : "잴 곳이 다 보이게 찍으세요")
                    .font(.caption).foregroundStyle(.white).padding(8).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                Spacer()
                Button {
                    if let r = cam.shoot() { onShot(r.0, r.1); dismiss() }
                } label: {
                    Circle().fill(.white).frame(width: 74, height: 74).overlay(Circle().stroke(.black.opacity(0.2), lineWidth: 3).padding(5))
                }.padding(.bottom, 34)
            }
        }
        .onAppear { cam.start() }
        .onDisappear { cam.stop() }
    }
}

// MARK: 메모 목록

struct MemoListScreen: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State private var camera = false
    @State private var pick: PhotosPickerItem?
    @State private var open: IdString?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { camera = true } label: { Label("사진 찍어 재기 (라이다)", systemImage: "camera") }
                    PhotosPicker(selection: $pick, matching: .images) { Label("앨범 사진으로", systemImage: "photo") }
                }
                Section("메모 \(store.site.memos.count)개") {
                    ForEach(store.site.memos) { m in
                        Button { open = IdString(id: m.id) } label: {
                            HStack(spacing: 12) {
                                if let img = UIImage(contentsOfFile: Store.docs.appendingPathComponent(m.photo).path) {
                                    Image(uiImage: img).resizable().scaledToFill().frame(width: 56, height: 56).clipped().cornerRadius(8)
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(m.title.isEmpty ? "실측 메모" : m.title).font(.body.weight(.semibold))
                                    Text("선 \(m.lines.count)개 · " + m.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }.foregroundStyle(.primary)
                    }
                    .onDelete { idx in
                        for i in idx { let m = store.site.memos[i]
                            for f in [m.photo, m.depth].compactMap({ $0 }) { try? FileManager.default.removeItem(at: Store.docs.appendingPathComponent(f)) } }
                        store.site.memos.remove(atOffsets: idx)
                    }
                }
            }
            .navigationTitle("실측 메모")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("닫기") { dismiss() } } }
            .fullScreenCover(isPresented: $camera) {
                MemoCameraScreen { photo, depth in add(photo, depth) }
            }
            .fullScreenCover(item: $open) { MemoEditor(memoId: $0.id).environmentObject(store) }
            .onChange(of: pick) { _, item in
                guard let item else { return }
                Task {
                    if let d = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: d)?.normalized(),
                       let jpg = img.jpegData(compressionQuality: 0.85) {
                        let n = "memo_\(uid()).jpg"
                        try? jpg.write(to: Store.docs.appendingPathComponent(n))
                        add(n, nil)
                    }
                    pick = nil
                }
            }
        }
    }

    func add(_ photo: String, _ depth: String?) {
        let m = MeasureMemo(title: "메모 \(store.site.memos.count + 1)", photo: photo, depth: depth)
        store.site.memos.insert(m, at: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { open = IdString(id: m.id) }
    }
}

// MARK: 메모 편집: 점 두 개 찍으면 선, 선 누르면 치수 입력

func memoText(_ l: MemoLine) -> String {
    let v = l.mm.map { "\($0)" } ?? l.auto.map { "약 \($0)" } ?? "?"
    return l.label.isEmpty ? v : "\(l.label) \(v)"
}

struct MemoEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let memoId: String
    @State private var img: UIImage?
    @State private var depth: MemoDepth?
    @State private var snapper: EdgeSnapper?
    @State private var first: CGPoint?
    @AppStorage("memoSnap") private var snapOn = true
    @State private var editLine: IdString?
    @State private var share: URL?
    @State private var autoSegs: [AutoSeg] = []
    @State private var pickSeg: Int? = nil          // 고른 자동 선
    @AppStorage("memoAutoLine2") private var autoOn = false

    var idx: Int? { store.site.memos.firstIndex { $0.id == memoId } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let i = idx, let img {
                    TextField("메모 이름 (예: 거실 소파 자리)", text: $store.site.memos[i].title)
                        .font(.headline).padding(.horizontal, 16).padding(.vertical, 8)
                    GeometryReader { geo in
                        let fit = fitRect(img.size, in: geo.size)
                        ZStack(alignment: .topLeading) {
                            Image(uiImage: img).resizable().frame(width: fit.width, height: fit.height).offset(x: fit.minX, y: fit.minY)
                            Canvas { ctx, _ in drawAuto(ctx, fit); draw(ctx, store.site.memos[i].lines, fit) }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(coordinateSpace: .local) { p in tap(p, fit, i) }
                    }
                    .background(Color.black)
                    HStack {
                        Toggle("선 자동", isOn: $autoOn).font(.subheadline).fixedSize()
                        Toggle("끝점 맞춤", isOn: $snapOn).font(.subheadline).fixedSize()
                        Spacer()
                        Button { if pickSeg != nil { pickSeg = nil } else if first != nil { first = nil } else if !store.site.memos[i].lines.isEmpty { store.site.memos[i].lines.removeLast() } } label: {
                            Label("되돌리기", systemImage: "arrow.uturn.backward")
                        }
                    }.padding(.horizontal, 16).padding(.vertical, 10)
                    Text(pickSeg != nil ? "다른 선을 누르면 두 선 사이, 같은 선을 또 누르면 그 선 길이, 빈 곳은 선에서 그 점까지" : first == nil ? (autoOn && !autoSegs.isEmpty ? "하늘색 선을 눌러 고르거나, 점을 찍어 직접 긋기 · 숫자를 누르면 치수 입력" : "선의 시작점을 누르세요 · 선 위 숫자를 누르면 치수 입력") : "끝점을 누르세요")
                        .font(.caption).foregroundStyle(.secondary).padding(.bottom, 10)
                } else {
                    ProgressView()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("닫기") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button { share = exportImage() } label: { Image(systemName: "square.and.arrow.up") } }
            }
            .sheet(item: $editLine) { e in
                if let i = idx { LineEditSheet(line: Binding(
                    get: { store.site.memos[i].lines.first { $0.id == e.id } ?? MemoLine(ax: 0, ay: 0, bx: 0, by: 0) },
                    set: { v in if let k = store.site.memos[i].lines.firstIndex(where: { $0.id == e.id }) { store.site.memos[i].lines[k] = v } }),
                    onDelete: { store.site.memos[i].lines.removeAll { $0.id == e.id } })
                    .presentationDetents([.medium]) }
            }
            .sheet(item: Binding(get: { share.map { ShareItem(url: $0) } }, set: { share = $0?.url })) { ShareSheet(items: [$0.url]) }
        }
        .onAppear(perform: load)
    }

    func load() {
        guard let i = idx else { return }
        let m = store.site.memos[i]
        img = UIImage(contentsOfFile: Store.docs.appendingPathComponent(m.photo).path)
        if let d = m.depth, let data = try? Data(contentsOf: Store.docs.appendingPathComponent(d)) {
            depth = try? JSONDecoder().decode(MemoDepth.self, from: data)
        }
        if let img { DispatchQueue.global(qos: .userInitiated).async {
            let s = EdgeSnapper(img), L = LineFinder.find(img)
            DispatchQueue.main.async { snapper = s; autoSegs = L } } }
    }

    func fitRect(_ s: CGSize, in box: CGSize) -> CGRect {
        let k = min(box.width / s.width, box.height / s.height)
        let w = s.width * k, h = s.height * k
        return CGRect(x: (box.width - w) / 2, y: (box.height - h) / 2, width: w, height: h)
    }

    func tap(_ p: CGPoint, _ fit: CGRect, _ i: Int) {
        // 선 숫자 누르기 → 편집
        if first == nil {
            for l in store.site.memos[i].lines {
                let m = CGPoint(x: fit.minX + (l.ax + l.bx) / 2 * fit.width, y: fit.minY + (l.ay + l.by) / 2 * fit.height)
                if hypot(m.x - p.x, m.y - p.y) < 28 { editLine = IdString(id: l.id); return }
            }
        }
        guard fit.contains(p) else { return }
        // 자동 선: 선 고르기 → 두 선 사이 / 그 선 길이 / 선에서 점까지
        if autoOn, first == nil, !autoSegs.isEmpty {
            let q = CGPoint(x: (p.x - fit.minX) / fit.width, y: (p.y - fit.minY) / fit.height)
            var hit: Int? = nil, hd = 18.0
            for (k, s) in autoSegs.enumerated() {
                let n = s.near(q), d = hypot((n.x - q.x) * fit.width, (n.y - q.y) * fit.height)
                if d < hd { hd = d; hit = k }
            }
            if let A = pickSeg {
                let a = autoSegs[A]
                var line: MemoLine
                if let B = hit, B == A { line = MemoLine(ax: a.a.x, ay: a.a.y, bx: a.b.x, by: a.b.y) }
                else if let B = hit {
                    let b = autoSegs[B]
                    // 두 선이 겹치는 구간 가운데에서 직각으로
                    let m = CGPoint(x: (a.a.x + a.b.x) / 2, y: (a.a.y + a.b.y) / 2), mb = CGPoint(x: (b.a.x + b.b.x) / 2, y: (b.a.y + b.b.y) / 2)
                    let c = CGPoint(x: (m.x + b.proj(m).x + mb.x + a.proj(mb).x) / 4, y: (m.y + b.proj(m).y + mb.y + a.proj(mb).y) / 4)
                    let pa = a.near(c), pb = b.near(a.near(c))
                    line = MemoLine(ax: pa.x, ay: pa.y, bx: pb.x, by: pb.y)
                } else { let pa = a.near(q); line = MemoLine(ax: pa.x, ay: pa.y, bx: q.x, by: q.y) }
                line.auto = depth?.length(line)
                store.site.memos[i].lines.append(line); pickSeg = nil
                editLine = IdString(id: line.id); return
            }
            if let h = hit { pickSeg = h; return }
        }
        var nx = (p.x - fit.minX) / fit.width, ny = (p.y - fit.minY) / fit.height
        if snapOn, let s = snapper { let q = s.snap(nx, ny); nx = q.0; ny = q.1 }
        if let a = first {
            var l = MemoLine(ax: a.x, ay: a.y, bx: nx, by: ny)
            l.auto = depth?.length(l)
            store.site.memos[i].lines.append(l)
            first = nil
            editLine = IdString(id: l.id)
        } else {
            first = CGPoint(x: nx, y: ny)
        }
    }

    func drawAuto(_ ctx: GraphicsContext, _ fit: CGRect) {
        guard autoOn else { return }
        for (k, s) in autoSegs.enumerated() {
            var p = Path(); p.move(to: CGPoint(x: fit.minX + s.a.x * fit.width, y: fit.minY + s.a.y * fit.height))
            p.addLine(to: CGPoint(x: fit.minX + s.b.x * fit.width, y: fit.minY + s.b.y * fit.height))
            let on = pickSeg == k
            ctx.stroke(p, with: .color(on ? Color.orange : Color.cyan.opacity(0.7)), lineWidth: on ? 4 : 1.6)
        }
    }

    func draw(_ ctx: GraphicsContext, _ lines: [MemoLine], _ fit: CGRect) {
        func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: fit.minX + x * fit.width, y: fit.minY + y * fit.height) }
        let yellow = Color(red: 1, green: 0.82, blue: 0.1)
        for l in lines {
            let a = pt(l.ax, l.ay), b = pt(l.bx, l.by)
            var path = Path(); path.move(to: a); path.addLine(to: b)
            ctx.stroke(path, with: .color(.black.opacity(0.6)), lineWidth: 4)
            ctx.stroke(path, with: .color(yellow), lineWidth: 2)
            for e in [a, b] { ctx.fill(Path(ellipseIn: CGRect(x: e.x - 4, y: e.y - 4, width: 8, height: 8)), with: .color(yellow)) }
            let m = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let t = ctx.resolve(Text(memoText(l)).font(.caption.weight(.bold)).foregroundColor(.black))
            let sz = t.measure(in: CGSize(width: 300, height: 40))
            let r = CGRect(x: m.x - sz.width / 2 - 6, y: m.y - sz.height / 2 - 3, width: sz.width + 12, height: sz.height + 6)
            ctx.fill(Path(roundedRect: r, cornerRadius: 6), with: .color(l.mm == nil ? Color.white.opacity(0.85) : yellow))
            ctx.draw(t, at: m)
        }
        if let f = first {
            let a = pt(f.x, f.y)
            ctx.stroke(Path(ellipseIn: CGRect(x: a.x - 9, y: a.y - 9, width: 18, height: 18)), with: .color(yellow), lineWidth: 2)
        }
    }

    func exportImage() -> URL? {
        guard let i = idx, let img else { return nil }
        let m = store.site.memos[i]
        let r = UIGraphicsImageRenderer(size: img.size)
        let out = r.image { c in
            img.draw(at: .zero)
            let s = max(img.size.width, img.size.height) / 1000
            for l in m.lines {
                let a = CGPoint(x: l.ax * img.size.width, y: l.ay * img.size.height), b = CGPoint(x: l.bx * img.size.width, y: l.by * img.size.height)
                let cg = c.cgContext
                cg.setStrokeColor(UIColor.black.withAlphaComponent(0.6).cgColor); cg.setLineWidth(6 * s)
                cg.move(to: a); cg.addLine(to: b); cg.strokePath()
                cg.setStrokeColor(UIColor(red: 1, green: 0.82, blue: 0.1, alpha: 1).cgColor); cg.setLineWidth(3 * s)
                cg.move(to: a); cg.addLine(to: b); cg.strokePath()
                let str = NSAttributedString(string: " \(memoText(l)) ", attributes: [
                    .font: UIFont.boldSystemFont(ofSize: 22 * s), .foregroundColor: UIColor.black,
                    .backgroundColor: UIColor(red: 1, green: 0.82, blue: 0.1, alpha: 0.95)])
                let sz = str.size()
                str.draw(at: CGPoint(x: (a.x + b.x) / 2 - sz.width / 2, y: (a.y + b.y) / 2 - sz.height / 2))
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(m.title.isEmpty ? "실측메모" : m.title).jpg")
        try? out.jpegData(compressionQuality: 0.9)?.write(to: url)
        return url
    }
}

struct LineEditSheet: View {
    @Binding var line: MemoLine
    var onDelete: () -> Void
    @Environment(\.dismiss) var dismiss
    @State private var text = ""
    @ObservedObject var laser = LaserLink.shared

    var body: some View {
        NavigationStack {
            Form {
                Section("무엇을 잰 선인가요") {
                    TextField("예: 소파 폭, 창 높이, 몰딩", text: $line.label)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack { ForEach(["폭", "높이", "깊이", "창", "문", "몰딩", "걸레받이", "가구", "콘센트"], id: \.self) { t in
                            Button(t) { line.label = t }.buttonStyle(.bordered)
                        } }
                    }
                }
                Section("치수 (mm)") {
                    TextField("측정기로 잰 값", text: $text).keyboardType(.numberPad)
                        .onChange(of: text) { _, v in line.mm = Int(v.filter(\.isNumber)) }
                    if let a = line.auto {
                        Button("라이다 값 쓰기: 약 \(a) mm") { text = "\(a)" }
                    } else {
                        Text("라이다 값 없음 (앨범 사진이거나 거리가 너무 멂)").font(.caption).foregroundStyle(.secondary)
                    }
                    if laser.connected {
                        Text("측정기 버튼을 누르면 값이 바로 들어옵니다").font(.caption).foregroundStyle(.green)
                    } else {
                        Text("라이카 DISTO를 연결하면(도면 화면 위 [측정기 연결]) 값이 바로 들어옵니다").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section { Button("이 선 지우기", role: .destructive) { onDelete(); dismiss() } }
            }
            .navigationTitle("선 치수").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("완료") { dismiss() } } }
            .onAppear { text = line.mm.map { "\($0)" } ?? "" }
            .onChange(of: laser.seq) { _, _ in if let v = laser.lastMM { text = "\(v)" } }
        }
    }
}
