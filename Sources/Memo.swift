import SwiftUI
import ARKit
import PhotosUI

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
        return Int((simd_distance(a, b) * 1000 / 5).rounded()) * 5
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
                            Canvas { ctx, _ in draw(ctx, store.site.memos[i].lines, fit) }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(coordinateSpace: .local) { p in tap(p, fit, i) }
                    }
                    .background(Color.black)
                    HStack {
                        Toggle("끝점 자동 맞춤", isOn: $snapOn).font(.subheadline).fixedSize()
                        Spacer()
                        Button { if first != nil { first = nil } else if !store.site.memos[i].lines.isEmpty { store.site.memos[i].lines.removeLast() } } label: {
                            Label("되돌리기", systemImage: "arrow.uturn.backward")
                        }
                    }.padding(.horizontal, 16).padding(.vertical, 10)
                    Text(first == nil ? "선의 시작점을 누르세요 · 선 위 숫자를 누르면 치수 입력" : "끝점을 누르세요")
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
        if let img { DispatchQueue.global(qos: .userInitiated).async { let s = EdgeSnapper(img); DispatchQueue.main.async { snapper = s } } }
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
                    Text("블루투스 레이저 측정기를 연결하면 여기에 바로 들어오게 됩니다").font(.caption).foregroundStyle(.secondary)
                }
                Section { Button("이 선 지우기", role: .destructive) { onDelete(); dismiss() } }
            }
            .navigationTitle("선 치수").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("완료") { dismiss() } } }
            .onAppear { text = line.mm.map { "\($0)" } ?? "" }
        }
    }
}
