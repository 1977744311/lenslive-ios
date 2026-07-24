import Foundation
import Testing
import GlassesKit

@Suite("GlassesSessionTracker 多路归并")
struct GlassesSessionTrackerTests {

    @Test("多路状态流归并为单一 GlassesHealth 快照流")
    func mergesAllStreamsIntoHealth() async throws {
        let mock = MockGlassesSession()
        let tracker = GlassesSessionTracker(provider: mock)
        let updates = StreamCollector(tracker.updates)

        await tracker.start()
        #expect(await updates.waitFor { $0.first == GlassesHealth() })   // 基线快照

        try await mock.start()
        try await mock.attachDisplay()
        await mock.injectThermal(.hot)

        let expected = GlassesHealth(session: .started, display: .started, camera: .stopped, thermal: .hot)
        #expect(await updates.waitFor { $0.last == expected })
        #expect(await tracker.current == expected)

        await tracker.stop()
    }

    @Test("等值变更去重，不重复发布")
    func deduplicatesUnchangedHealth() async throws {
        let mock = MockGlassesSession()
        let tracker = GlassesSessionTracker(provider: mock)
        let updates = StreamCollector(tracker.updates)

        await tracker.start()
        await mock.injectThermal(.warm)
        #expect(await updates.waitFor { $0.last?.thermal == .warm })

        let countBefore = updates.count
        await mock.injectThermal(.warm)   // 同值再注入
        // 给归并循环留出处理时间后确认无新发布
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(updates.count == countBefore)

        await tracker.stop()
    }

    @Test("新订阅者立即收到最近快照（replay）")
    func lateSubscriberReceivesLatestSnapshot() async throws {
        let mock = MockGlassesSession()
        let tracker = GlassesSessionTracker(provider: mock)
        await tracker.start()

        try await mock.start()
        #expect(await eventually { await tracker.current.session == .started })

        let late = StreamCollector(tracker.updates)
        #expect(await late.waitFor { $0.first?.session == .started })

        await tracker.stop()
    }
}
