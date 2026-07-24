import Foundation
import Testing
import GlassRenderer
import GlassesKit

@Suite("DisplayDispatcher 去重/节流/失败分类")
struct DisplayDispatcherTests {

    private func readyMock() async throws -> MockGlassesSession {
        let mock = MockGlassesSession()
        try await mock.start()
        try await mock.attachDisplay()
        return mock
    }

    private func node(_ label: String) -> GlassNode {
        .text(label, style: .body, color: .primary)
    }

    @Test("窗口内合并只发最新：A 立即发，B/C 合并为 C")
    func throttleMergesToLatestWithinWindow() async throws {
        let clock = VirtualClock()
        let mock = try await readyMock()
        let dispatcher = DisplayDispatcher(session: mock, clock: clock, window: 1)

        await dispatcher.submit(node("A"))
        #expect(await mock.sentPayloads.count == 1)   // 首帧立即发送

        await dispatcher.submit(node("B"))
        await dispatcher.submit(node("C"))
        #expect(await mock.sentPayloads.count == 1)   // 窗口内不发

        await clock.waitForSleepers(atLeast: 1)
        clock.advance(by: 1)

        #expect(await eventually { await mock.sentPayloads.count == 2 })
        let sent = await mock.sentPayloads
        #expect(sent[0].canonicalJSON.contains("A"))
        #expect(sent[1].canonicalJSON.contains("C"))
        #expect(!sent.contains { $0.canonicalJSON.contains("B") })   // B 被合并掉
    }

    @Test("与上次相同的内容跳过（幂等去重）")
    func duplicateContentIsSkipped() async throws {
        let clock = VirtualClock()
        let mock = try await readyMock()
        let dispatcher = DisplayDispatcher(session: mock, clock: clock, window: 1)

        await dispatcher.submit(node("A"))
        #expect(await mock.sentPayloads.count == 1)

        // 让窗口自然关闭（无 pending）
        await clock.waitForSleepers(atLeast: 1)
        clock.advance(by: 1)
        await clock.waitForSleepersDrained()

        await dispatcher.submit(node("A"))   // 与上次相同 → 跳过
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(await mock.sentPayloads.count == 1)

        await dispatcher.submit(node("D"))   // 不同内容 → 立即发送
        #expect(await eventually { await mock.sentPayloads.count == 2 })
    }

    @Test("窗口内合并后与上次相同 → 窗口结束不补发")
    func pendingEqualToLastSentIsDroppedAtWindowEnd() async throws {
        let clock = VirtualClock()
        let mock = try await readyMock()
        let dispatcher = DisplayDispatcher(session: mock, clock: clock, window: 1)

        await dispatcher.submit(node("A"))
        await dispatcher.submit(node("B"))
        await dispatcher.submit(node("A"))   // pending 收敛回 A == lastSent
        await clock.waitForSleepers(atLeast: 1)
        clock.advance(by: 1)
        await clock.waitForSleepersDrained()

        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(await mock.sentPayloads.count == 1)
    }

    @Test("断连失败 → 缓存最新帧，重挂后补发")
    func disconnectionCachesFrameForResendAfterReattach() async throws {
        let clock = VirtualClock()
        let mock = try await readyMock()
        let dispatcher = DisplayDispatcher(session: mock, clock: clock, window: 1)

        await mock.simulateBluetoothLoss()

        await dispatcher.submit(node("X"))
        await dispatcher.submit(node("Y"))   // 断连期间多次提交 → 只留最新
        #expect(await mock.sentPayloads.isEmpty)
        let cached = await dispatcher.cachedForResend
        #expect(cached?.canonicalJSON.contains("Y") == true)

        // 重连 + 重挂后补发
        await mock.setReachable(true)
        try await mock.start()
        try await mock.attachDisplay()
        await dispatcher.resendPendingAfterReattach()

        let sent = await mock.sentPayloads
        #expect(sent.count == 1)
        #expect(sent[0].canonicalJSON.contains("Y"))
        #expect(await dispatcher.cachedForResend == nil)
        #expect(await dispatcher.lastSentPayload == sent[0])
    }

    @Test("非断连失败 → 丢弃本帧，不缓存，可重试")
    func nonDisconnectionFailureDropsFrame() async throws {
        let clock = VirtualClock()
        let mock = try await readyMock()
        let dispatcher = DisplayDispatcher(session: mock, clock: clock, window: 1)

        await mock.failNextSend(.rendering("boom"))
        await dispatcher.submit(node("E"))

        #expect(await mock.sentPayloads.isEmpty)          // 未上屏
        #expect(await dispatcher.cachedForResend == nil)  // 不缓存
        #expect(await dispatcher.lastSentPayload == nil)

        // 渲染失败后窗口照常节流，窗口关闭后同内容可重试成功
        await clock.waitForSleepers(atLeast: 1)
        clock.advance(by: 1)
        await clock.waitForSleepersDrained()

        await dispatcher.submit(node("E"))
        #expect(await eventually { await mock.sentPayloads.count == 1 })
    }
}
