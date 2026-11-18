import Foundation
import RoomPlan

/// 같은 스캔(같은 좌표)으로 찍은 방들을 합쳐 집 전체 3D(USDZ)를 만든다.
@MainActor
enum House3D {
    static func build(_ site: Site) async -> (URL?, String?) {
        // 방이 가장 많은 스캔 묶음
        var groups: [String: [ScanRoom]] = [:]
        for r in site.rooms where r.raw != nil { groups[r.sessionId, default: []].append(r) }
        guard let rooms = groups.values.max(by: { $0.count < $1.count }), !rooms.isEmpty else {
            return (nil, "라이다로 스캔한 방이 없습니다")
        }
        var captured: [CapturedRoom] = []
        for r in rooms {
            if let f = r.raw, let d = try? Data(contentsOf: Store.docs.appendingPathComponent(f)),
               let c = try? JSONDecoder().decode(CapturedRoom.self, from: d) { captured.append(c) }
        }
        guard !captured.isEmpty else { return (nil, "스캔 원본을 읽지 못했습니다") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("집전체_\(site.name.isEmpty ? "현장" : site.name).usdz")
        try? FileManager.default.removeItem(at: url)
        do {
            if captured.count == 1 {
                try captured[0].export(to: url)
            } else {
                let b = StructureBuilder(options: [.beautifyObjects])
                let s = try await b.capturedStructure(from: captured)
                try s.export(to: url)
            }
            let note = groups.count > 1 ? "따로 찍은 스캔(\(groups.count - 1)묶음)은 좌표가 달라 빠졌습니다" : nil
            return (url, note)
        } catch {
            return (nil, "집 전체 3D 합치기 실패: \(error.localizedDescription)")
        }
    }
}
