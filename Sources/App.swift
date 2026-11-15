import SwiftUI
import RoomPlan
import QuickLook

@main
struct AnrakScanApp: App {
    @StateObject var store = Store()
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(store).preferredColorScheme(.light)
        }
    }
}

let bg = Color(red: 0xf2 / 255, green: 0xf4 / 255, blue: 0xf6 / 255)

func mm(_ v: Int) -> String {
    let f = NumberFormatter(); f.numberStyle = .decimal
    return f.string(from: NSNumber(value: v)) ?? "\(v)"
}

struct ContentView: View {
    @EnvironmentObject var store: Store
    @State private var scanning = false
    @State private var mode = 0           // 0 평면도, 1 천장도
    @State private var share: URL?
    @State private var preview: URL?
    @State private var confirmDelete: ScanRoom?
    @State private var editName: ScanRoom?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    planCard
                    if !store.site.rooms.isEmpty { roomList }
                    actions
                    Text("방마다 한 번씩 스캔하세요. 앱을 켠 채로 이어서 찍으면 방끼리 위치가 맞춰집니다. 결과는 안락실측의 [백업 불러오기]로 열면 평면도·3D·벽 면적이 그대로 나옵니다.")
                        .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)
                }
                .padding(16)
            }
            .background(bg.ignoresSafeArea())
            .navigationDestination(isPresented: $scanning) { CaptureScreen().environmentObject(store) }
            .sheet(item: Binding(get: { share.map { ShareItem(url: $0) } }, set: { share = $0?.url })) { item in
                ShareSheet(items: [item.url])
            }
            .sheet(item: Binding(get: { preview.map { ShareItem(url: $0) } }, set: { preview = $0?.url })) { item in
                QuickLookView(url: item.url).ignoresSafeArea()
            }
            .confirmationDialog("이 방을 지울까요?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
                Button("방 삭제", role: .destructive) { if let r = confirmDelete { store.delete(r) }; confirmDelete = nil }
            }
        }
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ANRAK SCAN").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(.secondary)
            TextField("현장 이름 (예: 장현호반 1209-202)", text: $store.site.name)
                .font(.title2.weight(.bold))
            TextField("주소", text: $store.site.addr).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4).padding(.top, 8)
    }

    var planCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $mode) {
                Text("평면도").tag(0); Text("천장도").tag(1)
            }.pickerStyle(.segmented)
            if store.site.rooms.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "viewfinder").font(.system(size: 36)).foregroundStyle(.secondary)
                    Text("아직 스캔한 방이 없습니다").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 240)
            } else {
                PlanCanvas(site: store.site, ceiling: mode == 1).frame(height: 320)
            }
        }
        .padding(14)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
    }

    var roomList: some View {
        VStack(spacing: 0) {
            ForEach(store.site.rooms) { r in
                let (cw, cd) = r.ceilingBox
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Menu {
                            ForEach(roomTypes, id: \.self) { t in
                                Button(t) { if let i = store.site.rooms.firstIndex(of: r) { store.site.rooms[i].name = t } }
                            }
                        } label: { Text(r.name).font(.headline).foregroundStyle(.black) }
                        Text("바닥 \(String(format: "%.1f", r.area))㎡ · 천장 높이 \(mm(r.ceil))").font(.subheadline)
                        Text("천장 \(mm(cw)) × \(mm(cd)) · 벽 도배 \(String(format: "%.1f", r.wallArea))㎡").font(.subheadline).foregroundStyle(.secondary)
                        Text("벽 \(r.walls.count)개 · 문 \(r.walls.flatMap { $0.ops }.filter { $0.kind == "door" }.count) · 창 \(r.walls.flatMap { $0.ops }.filter { $0.kind == "window" }.count)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 10) {
                        if let f = r.usdz {
                            Button("3D 보기") { preview = Store.docs.appendingPathComponent(f) }.font(.subheadline)
                        }
                        Button("삭제") { confirmDelete = r }.font(.subheadline).foregroundStyle(.red)
                    }
                }
                .padding(14)
                if r.id != store.site.rooms.last?.id { Divider().padding(.leading, 14) }
            }
        }
        .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
    }

    var actions: some View {
        VStack(spacing: 10) {
            Button {
                if RoomCaptureSession.isSupported { scanning = true }
            } label: {
                Label(store.site.rooms.isEmpty ? "방 스캔 시작" : "다음 방 스캔", systemImage: "camera.metering.matrix")
                    .fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 16)
                    .background(Color.black, in: RoundedRectangle(cornerRadius: 14)).foregroundStyle(.white)
            }
            if !RoomCaptureSession.isSupported {
                Text("이 기기는 라이다가 없어 스캔할 수 없습니다 (프로 모델 필요)").font(.footnote).foregroundStyle(.red)
            }
            if !store.site.rooms.isEmpty {
                Button { share = store.exportAnrakJSON() } label: {
                    Label("안락실측으로 보내기", systemImage: "square.and.arrow.up")
                        .fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 16)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 14)).foregroundStyle(.black)
                }
                Button { share = STLExport.build(store: store) } label: {
                    Label("3D 파일 보내기 (STL · mm)", systemImage: "cube")
                        .fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 16)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 14)).foregroundStyle(.black)
                }
            }
        }
    }
}

struct ShareItem: Identifiable { let url: URL; var id: String { url.path } }

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct QuickLookView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> QLPreviewController {
        let c = QLPreviewController(); c.dataSource = context.coordinator; return c
    }
    func updateUIViewController(_ vc: QLPreviewController, context: Context) {}
    func makeCoordinator() -> Coord { Coord(url: url) }
    final class Coord: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

/// 평면도·천장도 그림 (벽 안쪽 선 + 치수, 문·창)
struct PlanCanvas: View {
    let site: Site
    let ceiling: Bool

    var body: some View {
        Canvas { ctx, size in
            let b = planBounds(site.rooms, site.offsets)
            let pad = 34.0
            let sc = min((size.width - pad * 2) / max(b.maxX - b.minX, 1), (size.height - pad * 2) / max(b.maxY - b.minY, 1))
            let ox = (size.width - (b.maxX - b.minX) * sc) / 2, oy = (size.height - (b.maxY - b.minY) * sc) / 2
            func S(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - b.minX) * sc + ox, y: (p.y - b.minY) * sc + oy) }

            for r in site.rooms {
                let o = site.offsets[r.sessionId] ?? [0, 0]
                let lp = r.localPoints()
                let pp = lp.map { S(r.toPlan($0, dx: o[0], dy: o[1])) }
                let n = r.walls.count
                var path = Path(); path.move(to: pp[0]); for i in 1..<n { path.addLine(to: pp[i]) }; path.closeSubpath()
                ctx.fill(path, with: .color(ceiling ? Color(white: 0.97) : Color(red: 0.96, green: 0.94, blue: 0.90)))
                if ceiling {
                    // 천장: 옅은 격자
                    ctx.drawLayer { l in
                        l.clip(to: path)
                        let step = 300.0 * sc
                        var g = Path(); var x = 0.0
                        while x < size.width { g.move(to: CGPoint(x: x, y: 0)); g.addLine(to: CGPoint(x: x, y: size.height)); x += step }
                        l.stroke(g, with: .color(Color(white: 0.88)), lineWidth: 0.5)
                    }
                }
                ctx.stroke(path, with: .color(.black), lineWidth: 2.2)

                // 문·창
                if !ceiling {
                    for (i, w) in r.walls.enumerated() {
                        let a = lp[i], c = lp[i + 1]
                        let L = Double(max(w.len, 1))
                        for op in w.ops {
                            let t0 = Double(op.off) / L, t1 = Double(op.off + op.w) / L
                            let p0 = CGPoint(x: a.x + (c.x - a.x) * t0, y: a.y + (c.y - a.y) * t0)
                            let p1 = CGPoint(x: a.x + (c.x - a.x) * t1, y: a.y + (c.y - a.y) * t1)
                            var seg = Path(); seg.move(to: S(r.toPlan(p0, dx: o[0], dy: o[1]))); seg.addLine(to: S(r.toPlan(p1, dx: o[0], dy: o[1])))
                            ctx.stroke(seg, with: .color(op.kind == "door" ? Color(red: 0.62, green: 0.45, blue: 0.30) : Color(red: 0.35, green: 0.62, blue: 0.85)), lineWidth: 5)
                        }
                    }
                }
                // 벽 치수 (방 안쪽)
                let cx = pp.prefix(n).map { $0.x }.reduce(0, +) / Double(n), cy = pp.prefix(n).map { $0.y }.reduce(0, +) / Double(n)
                if !ceiling {
                    for i in 0..<n where Double(r.walls[i].len) * sc > 26 {
                        let m = CGPoint(x: (pp[i].x + pp[i + 1].x) / 2, y: (pp[i].y + pp[i + 1].y) / 2)
                        let dx = cx - m.x, dy = cy - m.y, d = max(hypot(dx, dy), 1)
                        let at = CGPoint(x: m.x + dx / d * 11, y: m.y + dy / d * 11)
                        ctx.draw(Text(mm(r.walls[i].len)).font(.system(size: 9)).foregroundColor(.gray), at: at)
                    }
                }
                let (cw, cd) = r.ceilingBox
                ctx.draw(Text(r.name).font(.system(size: 12, weight: .semibold)), at: CGPoint(x: cx, y: cy - 8))
                ctx.draw(Text(ceiling ? "H \(mm(r.ceil)) · \(mm(cw))×\(mm(cd))" : String(format: "%.1f㎡", r.area))
                    .font(.system(size: 9)).foregroundColor(.secondary), at: CGPoint(x: cx, y: cy + 7))
            }
        }
    }
}
