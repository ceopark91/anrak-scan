import SwiftUI
import RoomPlan
import QuickLook
import UniformTypeIdentifiers
import PhotosUI

@main
struct AnrakScanApp: App {
    @StateObject var store = Store()
    var body: some Scene {
        WindowGroup {
            TabView {
                PlanTab().tabItem { Label("도면", systemImage: "square.split.bottomrightquarter") }
                EstimateTab().tabItem { Label("견적", systemImage: "list.bullet.rectangle") }
                PriceTab().tabItem { Label("단가", systemImage: "wonsign.circle") }
            }
            .tint(.black)
            .environmentObject(store)
            .onOpenURL { u in if u.scheme == "anrakscan" { store.openScan = true } }   // 웹앱 [아이폰 라이다 스캔]
            .preferredColorScheme(.light)
        }
    }
}

let bg = Color(red: 0xf2 / 255, green: 0xf4 / 255, blue: 0xf6 / 255)

func mm(_ v: Int) -> String {
    let f = NumberFormatter(); f.numberStyle = .decimal
    return f.string(from: NSNumber(value: v)) ?? "\(v)"
}

struct ShareItem: Identifiable { let url: URL; var id: String { url.path } }
struct IdString: Identifiable { let id: String }

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

/// 3D 보기: 위에 항상 [닫기]가 있는 전체 화면
struct Preview3D: View {
    let url: URL
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Label("닫기", systemImage: "chevron.left").fontWeight(.semibold)
                }
                Spacer()
                Text("3D 보기").font(.headline)
                Spacer()
                Label("닫기", systemImage: "chevron.left").fontWeight(.semibold).hidden()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Color.white)
            .foregroundStyle(.black)
            QuickLookView(url: url)
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct BigButton: View {
    let title: String, icon: String, dark: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 15)
                .background(dark ? Color.black : Color.white, in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(dark ? .white : .black)
        }
    }
}

// MARK: - 도면 탭

struct PlanTab: View {
    @EnvironmentObject var store: Store
    @State private var scanning = false
    @State private var tracing = false
    @State private var mode = 0
    @State private var share: URL?
    @State private var preview: URL?
    @State private var confirmDelete: ScanRoom?
    @State private var edit: IdString?
    @State private var importing = false
    @State private var message: String?
    @State private var confirmSiteDelete = false
    @State private var zoomPlan = false
    @State private var building3D = false
    @State private var memos = false
    @State private var laserSheet = false
    @State private var sketching = false
    @State private var sketchEdit: IdString?
    @State private var ceilEdit: IdString?
    @State private var aimEdit: IdString?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("ANRAK").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(.secondary)
                        Spacer()
                        Button { laserSheet = true } label: { LaserBadge() }.foregroundStyle(.black)
                        Menu {
                            Button { store.newSite() } label: { Label("새 현장", systemImage: "plus") }
                            if !store.others.isEmpty {
                                Section("다른 현장 열기") {
                                    ForEach(store.others) { o in
                                        Button("\(o.name.isEmpty ? "이름 없는 현장" : o.name) · 방 \(o.rooms.count)") { store.open(o.id) }
                                    }
                                }
                            }
                            Button(role: .destructive) { confirmSiteDelete = true } label: { Label("이 현장 삭제", systemImage: "trash") }
                        } label: {
                            Label("현장 \(store.others.count + 1)", systemImage: "folder").font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 12).padding(.vertical, 7).background(Color.white, in: Capsule())
                        }.foregroundStyle(.black)
                    }
                    TextField("현장 이름 (예: 장현호반 1209-202)", text: $store.site.name).font(.title2.weight(.bold))
                    TextField("주소", text: $store.site.addr).font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4).padding(.top, 8)

                BigButton(title: "손으로 그리기 (대충 그리고 치수만)", icon: "scribble", dark: true) { sketching = true }

                Card {
                    HStack {
                        Picker("", selection: $mode) { Text("평면도").tag(0); Text("천장도").tag(1) }.pickerStyle(.segmented)
                        Button { store.site.turn = (store.site.turn + 1) % 4 } label: {
                            Image(systemName: "rotate.right").padding(8).background(Color(white: 0.93), in: Circle())
                        }.foregroundStyle(.black)
                    }
                    if store.site.rooms.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "scribble").font(.system(size: 36)).foregroundStyle(.secondary)
                            Text("여기를 눌러 방 모양을 손으로 그리세요").foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, minHeight: 220)
                        .contentShape(Rectangle()).onTapGesture { sketching = true }
                    } else {
                        PlanCanvas(rooms: store.site.placedRooms, ceiling: mode == 1).frame(height: 320)
                            .contentShape(Rectangle()).onTapGesture { zoomPlan = true }
                        Text("도면을 누르면 크게 봅니다").font(.caption2).foregroundStyle(.secondary)
                    }
                }

                if !store.site.rooms.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(store.site.rooms) { r in
                            roomRow(r)
                            if r.id != store.site.rooms.last?.id { Divider().padding(.leading, 14) }
                        }
                    }.background(Color.white, in: RoundedRectangle(cornerRadius: 16))
                }

                BigButton(title: store.site.rooms.isEmpty ? "라이다로 방 스캔" : "다음 방 스캔", icon: "camera.metering.matrix", dark: false) {
                    if RoomCaptureSession.isSupported { scanning = true } else { message = "이 기기는 라이다가 없어 스캔할 수 없습니다. 도면 불러오기를 써 주세요." }
                }
                BigButton(title: store.site.memos.isEmpty ? "사진 실측 메모 (점·선·치수)" : "사진 실측 메모 \(store.site.memos.count)개", icon: "ruler", dark: false) { memos = true }
                HStack(spacing: 10) {
                    BigButton(title: "사진·손도면", icon: "photo", dark: false) { tracing = true }
                    BigButton(title: "캐드(DXF)", icon: "doc.badge.plus", dark: false) { importing = true }
                }
                if !store.site.rooms.isEmpty {
                    Text("내보내기").font(.subheadline.weight(.semibold)).padding(.top, 6).padding(.horizontal, 4)
                    HStack(spacing: 10) {
                        BigButton(title: "도면 PDF", icon: "doc.richtext", dark: false) { share = Exporter.planPDF(store.site) }
                        BigButton(title: "캐드 DXF", icon: "square.and.pencil", dark: false) { share = Exporter.dxf(store.site) }
                    }
                    BigButton(title: building3D ? "3D 만드는 중…" : "집 전체 3D 보기", icon: "house", dark: true) {
                        guard !building3D else { return }
                        building3D = true
                        Task {
                            var u: URL? = nil, note: String? = nil
                            if store.site.rooms.contains(where: { $0.raw != nil }) { (u, note) = await House3D.build(store.site) }
                            if u == nil { u = Plan3D.build(store.site.placedRooms, name: store.site.name); note = u == nil ? "3D를 만들지 못했습니다" : nil }
                            building3D = false; message = note
                            if let u { preview = u }
                        }
                    }
                    BigButton(title: "웹앱으로 보내기 (복사 → 웹앱에서 붙여넣기)", icon: "doc.on.clipboard", dark: false) {
                        if let u = store.exportAnrakJSON(), let t = try? String(contentsOf: u, encoding: .utf8) {
                            UIPasteboard.general.string = t
                            message = "복사했습니다. 웹앱 실측 화면에서 [스캔 붙여넣기]를 누르세요"
                            if let w = URL(string: webAppURL) { UIApplication.shared.open(w) }
                        }
                    }
                    HStack(spacing: 10) {
                        BigButton(title: "안락실측", icon: "square.and.arrow.up", dark: false) { share = store.exportAnrakJSON() }
                        BigButton(title: "3D STL", icon: "cube", dark: false) { share = STLExport.build(store: store) }
                    }
                }
                if let m = message { Text(m).font(.footnote).foregroundStyle(.red).padding(.horizontal, 4) }
            }
            .padding(16)
        }
        .background(bg.ignoresSafeArea())
        .fullScreenCover(isPresented: $scanning) { CaptureScreen().environmentObject(store) }
        .sheet(isPresented: $laserSheet) { LaserSheet() }
        .onChange(of: store.openScan) { _, v in if v { store.openScan = false; if RoomCaptureSession.isSupported { scanning = true } } }
        .fullScreenCover(isPresented: $sketching) { SketchScreen().environmentObject(store) }
        .fullScreenCover(item: $sketchEdit) { SketchScreen(editRoomId: $0.id).environmentObject(store) }
        .fullScreenCover(item: $ceilEdit) { CeilingScreen(roomId: $0.id).environmentObject(store) }
        .fullScreenCover(item: $aimEdit) { AutoMeasureScreen(roomId: $0.id).environmentObject(store) }
        .onAppear { LaserLink.shared.wake() }
        .fullScreenCover(isPresented: $memos) { MemoListScreen().environmentObject(store) }
        .fullScreenCover(isPresented: $tracing) { TraceScreen().environmentObject(store) }
        .fullScreenCover(item: Binding(get: { preview.map { ShareItem(url: $0) } }, set: { preview = $0?.url })) { Preview3D(url: $0.url) }
        .sheet(item: Binding(get: { share.map { ShareItem(url: $0) } }, set: { share = $0?.url })) { ShareSheet(items: [$0.url]) }
        .sheet(item: $edit) { RoomEditSheet(roomId: $0.id).environmentObject(store) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "dxf") ?? .data, .data]) { res in
            guard case .success(let url) = res else { return }
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            let rooms = DXFImport.rooms(from: url)
            if rooms.isEmpty { message = "이 파일에서 닫힌 방 윤곽(폴리라인)을 찾지 못했습니다. 캐드에서 방마다 닫힌 폴리라인으로 그린 뒤 DXF로 저장해 주세요." }
            else { message = nil; for r in rooms { store.add(r) } }
        }
        .fullScreenCover(isPresented: $zoomPlan) { PlanZoom(rooms: store.site.placedRooms, ceiling: mode == 1) }
        .confirmationDialog("이 현장과 안의 방을 모두 지울까요?", isPresented: $confirmSiteDelete, titleVisibility: .visible) {
            Button("현장 삭제", role: .destructive) { store.deleteCurrentSite() }
        }
        .confirmationDialog("이 방을 지울까요?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
            Button("방 삭제", role: .destructive) { if let r = confirmDelete { store.delete(r) }; confirmDelete = nil }
        }
    }

    func roomRow(_ r: ScanRoom) -> some View {
        let (cw, cd) = r.ceilingBox
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(r.name).font(.headline)
                Text("바닥 \(String(format: "%.1f", r.area))㎡ (\(String(format: "%.1f", r.area / Calc.py))평) · 천장 높이 \(mm(r.ceil))").font(.subheadline)
                Text("천장 \(mm(cw)) × \(mm(cd)) · 둘레 \(String(format: "%.1f", Double(r.perimeter) / 1000))m").font(.subheadline).foregroundStyle(.secondary)
                if !(r.fixtures ?? []).isEmpty {
                    Text("천장: " + fixtureKinds.compactMap { k in r.count(k.0) > 0 ? "\(k.1) \(r.count(k.0))" : nil }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
                if r.gap > 60 { Text("벽 길이가 서로 안 맞습니다 (끝점 \(mm(r.gap))mm 어긋남)").font(.caption).foregroundStyle(.red) }
                Text((r.mold?.k == "crown" ? "각몰딩 \(r.mold!.w)·\(r.mold!.a)°" : "몰딩 \(moldName(r.moldType))") + (r.ceilT == "well" ? " · 우물 \((r.wells ?? []).count)" : "") + ((r.marks ?? []).isEmpty ? "" : " · 조명 \((r.marks ?? []).filter { $0.k == "light" }.count) · 실링팬 \((r.marks ?? []).filter { $0.k == "fan" }.count)") + " · 걸레받이 \((r.baseH ?? 0) == 0 ? "없음" : "\(r.baseH ?? 0)mm") · 도배 높이 \(mm(r.paperH))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 10) {
                Button("도면 고치기") { sketchEdit = IdString(id: r.id) }.font(.subheadline.weight(.semibold))
                Button("겨눠서 재기") { aimEdit = IdString(id: r.id) }.font(.subheadline)
                Button("천장·몰딩") { ceilEdit = IdString(id: r.id) }.font(.subheadline)
                Button("방 정보") { edit = IdString(id: r.id) }.font(.subheadline)
                if let f = r.usdz { Button("3D 보기") { preview = Store.docs.appendingPathComponent(f) }.font(.subheadline) }
                else { Button("3D 보기") { preview = Plan3D.build([store.site.placed(r)], name: r.name) }.font(.subheadline) }
                Button("삭제") { confirmDelete = r }.font(.subheadline).foregroundStyle(.red)
            }
        }
        .padding(14)
    }
}

/// 평면도·천장도 그림 (벽 안쪽 선 + 치수, 문·창). rooms는 정렬·위치 보정이 끝난 방
struct PlanCanvas: View {
    let rooms: [ScanRoom]
    let ceiling: Bool
    var fontScale: Double = 1

    var body: some View {
        Canvas { ctx, size in
            let b = planBounds(rooms, [:])
            let pad = 34.0
            let sc = min((size.width - pad * 2) / max(b.maxX - b.minX, 1), (size.height - pad * 2) / max(b.maxY - b.minY, 1))
            let ox = (size.width - (b.maxX - b.minX) * sc) / 2, oy = (size.height - (b.maxY - b.minY) * sc) / 2
            func S(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - b.minX) * sc + ox, y: (p.y - b.minY) * sc + oy) }
            let fs = 9 * fontScale

            for r in rooms {
                let lp = r.localPoints()
                let pp = lp.map { S(r.toPlan($0)) }
                let n = r.walls.count
                guard n >= 3 else { continue }
                var path = Path(); path.move(to: pp[0]); for i in 1..<n { path.addLine(to: pp[i]) }; path.closeSubpath()
                ctx.fill(path, with: .color(ceiling ? Color(white: 0.97) : Color(red: 0.96, green: 0.94, blue: 0.90)))
                if ceiling {
                    ctx.drawLayer { l in
                        l.clip(to: path)
                        let step = max(300.0 * sc, 3)
                        var g = Path(); var x = 0.0
                        while x < size.width { g.move(to: CGPoint(x: x, y: 0)); g.addLine(to: CGPoint(x: x, y: size.height)); x += step }
                        l.stroke(g, with: .color(Color(white: 0.88)), lineWidth: 0.5)
                    }
                }
                ctx.stroke(path, with: .color(.black), lineWidth: 2.2)
                if !ceiling {
                    for (i, w) in r.walls.enumerated() {
                        let a = lp[i], c = lp[i + 1]
                        let L = Double(max(w.len, 1))
                        for op in w.ops {
                            let t0 = Double(op.off) / L, t1 = Double(op.off + op.w) / L
                            let p0 = CGPoint(x: a.x + (c.x - a.x) * t0, y: a.y + (c.y - a.y) * t0)
                            let p1 = CGPoint(x: a.x + (c.x - a.x) * t1, y: a.y + (c.y - a.y) * t1)
                            var seg = Path(); seg.move(to: S(r.toPlan(p0))); seg.addLine(to: S(r.toPlan(p1)))
                            ctx.stroke(seg, with: .color(op.kind == "door" ? Color(red: 0.62, green: 0.45, blue: 0.30) : Color(red: 0.35, green: 0.62, blue: 0.85)), lineWidth: 5)
                        }
                    }
                }
                for fx in r.fixtures ?? [] {
                    let c = S(r.toPlan(CGPoint(x: fx.x, y: fx.y)))
                    let rr = ceiling ? 6.0 : 3.5
                    let box = CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2)
                    let col = Color(red: 0.85, green: 0.55, blue: 0.10)
                    switch fx.kind {
                    case "light", "down":
                        ctx.fill(Path(ellipseIn: box), with: .color(.white)); ctx.stroke(Path(ellipseIn: box), with: .color(col), lineWidth: 1.5)
                        var x = Path(); x.move(to: CGPoint(x: box.minX + 1.5, y: box.minY + 1.5)); x.addLine(to: CGPoint(x: box.maxX - 1.5, y: box.maxY - 1.5))
                        x.move(to: CGPoint(x: box.maxX - 1.5, y: box.minY + 1.5)); x.addLine(to: CGPoint(x: box.minX + 1.5, y: box.maxY - 1.5))
                        if fx.kind == "light" { ctx.stroke(x, with: .color(col), lineWidth: 1) }
                    case "aircon", "hatch", "vent":
                        let b2 = box.insetBy(dx: fx.kind == "aircon" ? -3 : 0, dy: fx.kind == "aircon" ? -3 : 0)
                        ctx.fill(Path(b2), with: .color(.white)); ctx.stroke(Path(b2), with: .color(.blue), lineWidth: 1.5)
                    default:
                        ctx.fill(Path(ellipseIn: box.insetBy(dx: 1.5, dy: 1.5)), with: .color(.red))
                    }
                    if ceiling { ctx.draw(Text(fixtureName(fx.kind)).font(.system(size: fs * 0.85)).foregroundColor(.secondary), at: CGPoint(x: c.x, y: c.y + rr + 6)) }
                }
                let cx = pp.prefix(n).map { $0.x }.reduce(0, +) / Double(n), cy = pp.prefix(n).map { $0.y }.reduce(0, +) / Double(n)
                for i in 0..<n where Double(r.walls[i].len) * sc > 26 {
                    let m = CGPoint(x: (pp[i].x + pp[i + 1].x) / 2, y: (pp[i].y + pp[i + 1].y) / 2)
                    let dx = cx - m.x, dy = cy - m.y, d = max(hypot(dx, dy), 1)
                    let at = CGPoint(x: m.x + dx / d * 12, y: m.y + dy / d * 12)
                    ctx.draw(Text(mm(r.walls[i].len)).font(.system(size: fs)).foregroundColor(.gray), at: at)
                }
                let (cw, cd) = r.ceilingBox
                ctx.draw(Text(r.name).font(.system(size: fs + 3, weight: .semibold)), at: CGPoint(x: cx, y: cy - 8))
                ctx.draw(Text(ceiling ? "H \(mm(r.ceil)) · \(mm(cw))×\(mm(cd))" : String(format: "%.1f㎡", r.area))
                    .font(.system(size: fs)).foregroundColor(.secondary), at: CGPoint(x: cx, y: cy + 7))
            }
        }
    }
}

/// 도면 크게 보기: 두 손가락으로 확대, 끌어서 이동
struct PlanZoom: View {
    let rooms: [ScanRoom]
    let ceiling: Bool
    @Environment(\.dismiss) var dismiss
    @State private var scale: CGFloat = 1
    @State private var last: CGFloat = 1
    @State private var off: CGSize = .zero
    @State private var lastOff: CGSize = .zero

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: { Label("닫기", systemImage: "chevron.left").fontWeight(.semibold) }
                Spacer()
                Text(ceiling ? "천장도" : "평면도").font(.headline)
                Spacer()
                Button("맞춤") { scale = 1; last = 1; off = .zero; lastOff = .zero }.fontWeight(.semibold)
            }
            .padding(.horizontal, 16).padding(.vertical, 12).foregroundStyle(.black)
            GeometryReader { geo in
                PlanCanvas(rooms: rooms, ceiling: ceiling, fontScale: 1.1 / max(1, Double(scale) * 0.6))
                    .frame(width: geo.size.width, height: geo.size.height)
                    .scaleEffect(scale).offset(off)
                    .contentShape(Rectangle())
                    .gesture(
                        MagnificationGesture()
                            .onChanged { v in scale = min(8, max(1, last * v)) }
                            .onEnded { _ in last = scale }
                            .simultaneously(with: DragGesture()
                                .onChanged { v in off = CGSize(width: lastOff.width + v.translation.width, height: lastOff.height + v.translation.height) }
                                .onEnded { _ in lastOff = off })
                    )
            }
            .clipped()
            Text("두 손가락으로 확대 · 끌어서 이동").font(.caption).foregroundStyle(.secondary).padding(8)
        }
        .background(Color.white)
    }
}
