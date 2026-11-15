import SwiftUI
import PhotosUI

/// 사진·손도면·캡처한 평면도 위에 방 모서리를 찍어 방을 만든다.
/// 첫 방은 벽 하나의 실제 길이(mm)를 넣어 축척을 맞추고, 그 뒤 방들은 같은 축척을 쓴다.
struct TraceScreen: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State private var item: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var pts: [CGPoint] = []          // 그림 좌표(px)
    @State private var mmPerPx: Double? = nil
    @State private var askLen = false
    @State private var lenText = ""
    @State private var name = "거실"
    @State private var done: [[CGPoint]] = []
    @State private var zoom: CGFloat = 1
    private let sid = "trace-" + uid()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: { Label("닫기", systemImage: "chevron.left").fontWeight(.semibold) }
                Spacer()
                Text("사진·손도면 따라 그리기").font(.headline)
                Spacer()
                PhotosPicker(selection: $item, matching: .images) { Text(image == nil ? "사진" : "바꾸기").fontWeight(.semibold) }
            }
            .padding(.horizontal, 16).padding(.vertical, 12).foregroundStyle(.black)

            if let img = image {
                GeometryReader { geo in
                    let fit = min(geo.size.width / img.size.width, geo.size.height / img.size.height)
                    let sc = fit * zoom
                    ScrollView([.horizontal, .vertical]) {
                        ZStack(alignment: .topLeading) {
                            Image(uiImage: img).resizable().frame(width: img.size.width * sc, height: img.size.height * sc)
                            Canvas { ctx, _ in
                                for d in done {
                                    var p = Path(); p.move(to: CGPoint(x: d[0].x * sc, y: d[0].y * sc))
                                    for q in d.dropFirst() { p.addLine(to: CGPoint(x: q.x * sc, y: q.y * sc)) }
                                    p.closeSubpath()
                                    ctx.fill(p, with: .color(.blue.opacity(0.15))); ctx.stroke(p, with: .color(.blue), lineWidth: 2)
                                }
                                if !pts.isEmpty {
                                    var p = Path(); p.move(to: CGPoint(x: pts[0].x * sc, y: pts[0].y * sc))
                                    for q in pts.dropFirst() { p.addLine(to: CGPoint(x: q.x * sc, y: q.y * sc)) }
                                    ctx.stroke(p, with: .color(.red), lineWidth: 2.5)
                                    for (i, q) in pts.enumerated() {
                                        let r = CGRect(x: q.x * sc - 5, y: q.y * sc - 5, width: 10, height: 10)
                                        ctx.fill(Path(ellipseIn: r), with: .color(i == 0 ? .green : .red))
                                    }
                                }
                            }
                            .frame(width: img.size.width * sc, height: img.size.height * sc)
                            .contentShape(Rectangle())
                            .gesture(SpatialTapGesture().onEnded { v in tap(CGPoint(x: v.location.x / sc, y: v.location.y / sc)) })
                        }
                    }
                }
                .background(Color(white: 0.9))
                controls
            } else {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("손으로 그린 도면, 분양 평면도 캡처, 캐드 출력물 사진을 고르세요").multilineTextAlignment(.center).foregroundStyle(.secondary)
                    PhotosPicker(selection: $item, matching: .images) {
                        Text("사진 고르기").fontWeight(.semibold).padding(.horizontal, 24).padding(.vertical, 12)
                            .background(Color.black, in: RoundedRectangle(cornerRadius: 12)).foregroundStyle(.white)
                    }
                }.padding(30)
                Spacer()
            }
        }
        .background(Color.white)
        .onChange(of: item) { _, it in
            guard let it else { return }
            Task {
                if let d = try? await it.loadTransferable(type: Data.self), let u = UIImage(data: d) {
                    await MainActor.run { image = u.normalized(); pts = []; done = []; mmPerPx = nil; zoom = 1 }
                }
            }
        }
        .alert("첫 번째 벽(초록 점에서 시작한 변)의 실제 길이", isPresented: $askLen) {
            TextField("mm (예: 3600)", text: $lenText).keyboardType(.numberPad)
            Button("확인") { if let v = Double(lenText), v > 100, pts.count >= 2 {
                mmPerPx = v / max(hypot(pts[1].x - pts[0].x, pts[1].y - pts[0].y), 1); finishRoom() } }
            Button("취소", role: .cancel) {}
        } message: { Text("이 길이로 그림 전체의 축척을 맞춥니다.") }
    }

    var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(pts.count < 3 ? "방 모서리를 시계 방향으로 차례로 누르세요 (거의 수평·수직이면 자동으로 맞춰짐)" : "모서리 \(pts.count)개 · 다 찍었으면 [방 완성]")
                .font(.footnote).foregroundStyle(.secondary)
            ChipRow(title: "", options: roomTypes.map { ($0, $0) }, sel: $name)
            HStack(spacing: 8) {
                Button { zoom = max(1, zoom / 1.5) } label: { Image(systemName: "minus.magnifyingglass").padding(12).background(Color(white: 0.93), in: RoundedRectangle(cornerRadius: 10)) }
                Button { zoom = min(6, zoom * 1.5) } label: { Image(systemName: "plus.magnifyingglass").padding(12).background(Color(white: 0.93), in: RoundedRectangle(cornerRadius: 10)) }
                Button { if !pts.isEmpty { pts.removeLast() } } label: {
                    Text("한 점 취소").fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Color(white: 0.93), in: RoundedRectangle(cornerRadius: 10))
                }
                Button { if mmPerPx == nil { lenText = ""; askLen = true } else { finishRoom() } } label: {
                    Text("방 완성").fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(pts.count >= 3 ? Color.black : Color(white: 0.8), in: RoundedRectangle(cornerRadius: 10)).foregroundStyle(.white)
                }.disabled(pts.count < 3)
            }.foregroundStyle(.black)
        }
        .padding(14)
    }

    func tap(_ p: CGPoint) {
        var q = p
        if let prev = pts.last {
            let a = abs(atan2(q.y - prev.y, q.x - prev.x) * 180 / .pi)
            if a < 8 || a > 172 { q.y = prev.y } else if abs(a - 90) < 8 { q.x = prev.x }
        }
        pts.append(q)
    }

    func finishRoom() {
        guard let k = mmPerPx, pts.count >= 3 else { return }
        let q = pts.map { CGPoint(x: $0.x * k, y: $0.y * k) }
        if let r = PlanGeometry.room(from: q, ops: [], floorY: 0) {
            var room = ScanRoom(id: uid(), name: name, sessionId: sid, x: r.x, y: r.y, rot: r.rot, ceil: 2300, walls: r.walls, usdz: nil, date: Date())
            room.moldType = "none"; room.baseH = 0
            store.add(room)
            done.append(pts)
        }
        pts = []
    }
}

extension UIImage {
    /// 사진 방향 정보를 없앤(똑바로 선) 그림, 긴 변 2000px 이하
    func normalized() -> UIImage {
        let m = max(size.width, size.height)
        let k = m > 2000 ? 2000 / m : 1
        let s = CGSize(width: size.width * k, height: size.height * k)
        let f = UIGraphicsImageRendererFormat(); f.scale = 1
        return UIGraphicsImageRenderer(size: s, format: f).image { _ in draw(in: CGRect(origin: .zero, size: s)) }
    }
}
