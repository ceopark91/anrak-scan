import SwiftUI
import CoreBluetooth

// MARK: - 라이카 DISTO 블루투스 레이저 측정기 (Bluetooth Smart, 공개 규격)
// 측정기에서 버튼을 누르면 거리(m, Float32)가 알림으로 들어온다. 앱에서 측정 명령("g")도 보낼 수 있다.

enum Disto {
    static let service = CBUUID(string: "3AB10100-F831-4395-B29D-570977D5BF94")
    static let distance = CBUUID(string: "3AB10101-F831-4395-B29D-570977D5BF94")
    static let command = CBUUID(string: "3AB10109-F831-4395-B29D-570977D5BF94")
}

final class LaserLink: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let shared = LaserLink()

    @Published var status = "연결 안 됨"
    @Published var connectedName: String?
    @Published var found: [CBPeripheral] = []
    @Published var lastMM: Int?
    @Published var seq = 0          // 새 값이 올 때마다 1씩 (같은 값이 와도 알 수 있게)
    @Published var scanning = false

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var cmdChar: CBCharacteristic?
    private var wantScan = false
    private let savedKey = "distoId"

    var connected: Bool { connectedName != nil }

    /// 앱 시작 때 부름: 전에 연결했던 측정기가 있으면 자동 연결
    func wake() {
        guard UserDefaults.standard.string(forKey: savedKey) != nil else { return }
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
    }

    func startScan() {
        found = []; wantScan = true
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
        else if central?.state == .poweredOn { beginScan() }
    }
    func stopScan() { wantScan = false; scanning = false; central?.stopScan() }

    private func beginScan() {
        guard let c = central else { return }
        scanning = true; status = "측정기 찾는 중… (측정기 블루투스를 켜 주세요)"
        // 이미 시스템에 연결된 DISTO도 목록에 넣기
        for p in c.retrieveConnectedPeripherals(withServices: [Disto.service]) where !found.contains(p) { found.append(p) }
        c.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func connect(_ p: CBPeripheral) {
        stopScan()
        peripheral = p; p.delegate = self
        status = "연결 중… \(p.name ?? "DISTO")"
        central?.connect(p)
    }
    func disconnect() {
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        UserDefaults.standard.removeObject(forKey: savedKey)
        peripheral = nil; connectedName = nil; cmdChar = nil; status = "연결 안 됨"
    }
    /// 앱에서 측정 버튼 누르기 (지원 모델만)
    func trigger() {
        guard let p = peripheral, let c = cmdChar, let d = "g".data(using: .ascii) else { return }
        p.writeValue(d, for: c, type: c.properties.contains(.write) ? .withResponse : .withoutResponse)
    }

    // CBCentralManagerDelegate
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:
            if let s = UserDefaults.standard.string(forKey: savedKey), let id = UUID(uuidString: s),
               let p = c.retrievePeripherals(withIdentifiers: [id]).first, peripheral == nil {
                connect(p)
            }
            if wantScan { beginScan() }
        case .unauthorized: status = "설정 > 안락 실측 > 블루투스를 켜 주세요"
        case .poweredOff: status = "아이폰 블루투스가 꺼져 있습니다"
        default: break
        }
    }
    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData ad: [String: Any], rssi: NSNumber) {
        let name = (ad[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        let uuids = (ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        guard uuids.contains(Disto.service) || name.uppercased().contains("DISTO") else { return }
        if !found.contains(p) { found.append(p) }
    }
    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        status = "연결됨, 준비 중…"
        p.discoverServices([Disto.service])
    }
    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        status = "연결 실패: \(error?.localizedDescription ?? "다시 시도해 주세요")"
    }
    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        connectedName = nil; cmdChar = nil
        if UserDefaults.standard.string(forKey: savedKey) != nil {
            status = "끊김, 다시 연결 중…"; c.connect(p)   // 측정기가 다시 켜지면 자동 연결
        } else { status = "연결 안 됨" }
    }

    // CBPeripheralDelegate
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == Disto.service }) else {
            status = "DISTO 측정기가 아닙니다 (블루투스 지원 모델인지 확인)"; return
        }
        p.discoverCharacteristics(nil, for: s)
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            if ch.properties.contains(.notify) || ch.properties.contains(.indicate) { p.setNotifyValue(true, for: ch) }
            if ch.uuid == Disto.command { cmdChar = ch }
        }
        connectedName = p.name ?? "DISTO"
        status = "연결됨: \(connectedName!) · 측정기 버튼을 누르면 값이 들어옵니다"
        UserDefaults.standard.set(p.identifier.uuidString, forKey: savedKey)
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard ch.uuid == Disto.distance, let d = ch.value, d.count >= 4 else { return }
        let bits = d.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let m = Float(bitPattern: UInt32(littleEndian: bits))
        guard m.isFinite, m > 0, m < 300 else { return }
        lastMM = Int((Double(m) * 1000).rounded())
        seq += 1
    }
}

// MARK: - 라이다 보정 (측정기가 없을 때): 길이를 아는 물건을 재서 배율을 맞춘다

enum LidarCal {
    static var scale: Double {
        let v = UserDefaults.standard.double(forKey: "lidarScale")
        return v > 0.8 && v < 1.2 ? v : 1
    }
    static func set(measuredRaw: Int, actual: Int) -> Bool {
        guard measuredRaw > 100, actual > 100 else { return false }
        let s = Double(actual) / Double(measuredRaw)
        guard s > 0.8, s < 1.2 else { return false }
        UserDefaults.standard.set(s, forKey: "lidarScale")
        return true
    }
    static func reset() { UserDefaults.standard.removeObject(forKey: "lidarScale") }
    static var text: String {
        let p = (scale - 1) * 100
        return abs(p) < 0.05 ? "보정 없음" : String(format: "%@%.1f%% 보정 중", p > 0 ? "+" : "", p)
    }
}

// MARK: - 측정기 화면

struct LaserSheet: View {
    @ObservedObject var laser = LaserLink.shared
    @Environment(\.dismiss) var dismiss
    @State private var calib = false
    @State private var rawMeasured: Int?
    @State private var actualText = ""
    @State private var calMsg: String?
    @State private var scaleText = LidarCal.text

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(laser.status).font(.subheadline)
                    if laser.connected {
                        if let v = laser.lastMM { Text("마지막 값  \(mm(v)) mm").font(.title2.weight(.bold)) }
                        Button("앱에서 측정하기") { laser.trigger() }
                        Button("연결 끊기", role: .destructive) { laser.disconnect() }
                    } else {
                        Button(laser.scanning ? "찾는 중…" : "측정기 찾기") { laser.startScan() }
                        ForEach(laser.found, id: \.identifier) { p in
                            Button("연결: \(p.name ?? "DISTO")") { laser.connect(p) }
                        }
                    }
                } header: { Text("라이카 DISTO 레이저 측정기") } footer: {
                    Text("D1·D2·D110·X3·X4 등 블루투스 모델. 한 번 연결하면 다음부터 측정기를 켜기만 하면 자동으로 붙습니다. 연결되면 방 고치기·카메라 자·사진 메모에서 측정기 버튼만 누르면 값이 바로 들어갑니다.")
                }
                Section {
                    HStack { Text("지금 상태"); Spacer(); Text(scaleText).foregroundStyle(.secondary) }
                    Button("길이 아는 물건으로 보정하기") { calib = true }
                    if let r = rawMeasured {
                        Text("라이다로 잰 값: \(mm(r)) mm")
                        HStack {
                            TextField("실제 길이 mm (줄자·레이저)", text: $actualText).keyboardType(.numberPad)
                            if laser.connected { Button("레이저 값") { actualText = laser.lastMM.map { "\($0)" } ?? "" }.buttonStyle(.bordered) }
                        }
                        Button("이 값으로 보정") {
                            if LidarCal.set(measuredRaw: r, actual: Int(actualText) ?? 0) {
                                calMsg = "보정했습니다. 앞으로 스캔·카메라 자·사진 메모에 적용됩니다."; rawMeasured = nil; actualText = ""
                            } else { calMsg = "차이가 20% 넘게 나서 적용하지 않았습니다. 다시 재 주세요." }
                            scaleText = LidarCal.text
                        }.fontWeight(.semibold)
                    }
                    if let m = calMsg { Text(m).font(.caption).foregroundStyle(.secondary) }
                    Button("보정 지우기") { LidarCal.reset(); scaleText = LidarCal.text }
                } header: { Text("라이다 보정 (측정기 없을 때)") } footer: {
                    Text("문 폭, 방 한쪽 벽처럼 1m 넘고 줄자로 정확히 잰 길이를 카메라 자로 한 번 재면, 이 아이폰 라이다의 오차 배율을 맞춥니다. 길수록 정확합니다. 이미 저장한 방은 바뀌지 않고 다음 스캔부터 적용됩니다.")
                }
            }
            .navigationTitle("측정기 · 보정").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { laser.stopScan(); dismiss() } } }
            .fullScreenCover(isPresented: $calib) {
                MeasureScreen(title: "기준 길이 재기") { v in rawMeasured = Int((Double(v) / LidarCal.scale).rounded()) }
            }
        }
    }
}

/// 상단에 붙이는 작은 측정기 상태 버튼
struct LaserBadge: View {
    @ObservedObject var laser = LaserLink.shared
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(laser.connected ? Color.green : Color(white: 0.75)).frame(width: 8, height: 8)
            Text(laser.connected ? "측정기" : "측정기 연결").font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 12).padding(.vertical, 7).background(Color.white, in: Capsule())
    }
}
