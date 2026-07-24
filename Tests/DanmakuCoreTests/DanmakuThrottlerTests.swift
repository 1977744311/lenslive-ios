import XCTest
import DanmakuCore

final class DanmakuThrottlerTests: XCTestCase {
    func testWindowAggregatesIntoSingleBatch() async {
        let clock = TestClock()
        let throttler = DanmakuThrottler(clock: clock)
        let recorder = StreamRecorder(throttler.batches)

        await throttler.submit(makeEvent(id: "1"))
        await throttler.submit(makeEvent(id: "2"))
        await throttler.submit(makeEvent(id: "3"))

        await expectSleepers(clock, atLeast: 1)
        XCTAssertTrue(recorder.items.isEmpty, "窗口未到期不应输出")
        XCTAssertEqual(clock.recordedSleepDurations, [1.0], "默认窗口 1s")

        clock.advance(by: 1)

        await expectEventually { recorder.items.count == 1 }
        XCTAssertEqual(recorder.items[0].map(\.id), ["1", "2", "3"])
        XCTAssertEqual(clock.sleeperCount, 0, "空闲期不应有定时器")
    }

    func testIdleThenNextWindowStartsOnSubmit() async {
        let clock = TestClock()
        let throttler = DanmakuThrottler(clock: clock)
        let recorder = StreamRecorder(throttler.batches)

        await throttler.submit(makeEvent(id: "1"))
        await expectSleepers(clock, atLeast: 1)
        clock.advance(by: 1)
        await expectEventually { recorder.items.count == 1 }

        // 空闲一段时间后再来事件，开启新窗口
        clock.advance(by: 10)
        await throttler.submit(makeEvent(id: "2"))
        await expectSleepers(clock, atLeast: 1)
        clock.advance(by: 1)

        await expectEventually { recorder.items.count == 2 }
        XCTAssertEqual(recorder.items[1].map(\.id), ["2"])
    }

    func testFloodDropsPlainChatKeepsHighValue() async {
        let clock = TestClock()
        let throttler = DanmakuThrottler(clock: clock)
        let recorder = StreamRecorder(throttler.batches)

        // 25 条 > 默认阈值 20：21 条普通 chat + 2 条提问 + 1 礼物 + 1 SC
        for index in 0..<21 {
            await throttler.submit(makeEvent(id: "plain-\(index)"))
        }
        await throttler.submit(makeEvent(id: "q-1", isQuestion: true))
        await throttler.submit(makeEvent(id: "gift-1", kind: .gift, value: 5))
        await throttler.submit(makeEvent(id: "q-2", isQuestion: true))
        await throttler.submit(makeEvent(id: "sc-1", kind: .superChat, value: 30))

        await expectSleepers(clock, atLeast: 1)
        clock.advance(by: 1)

        await expectEventually { recorder.items.count == 1 }
        XCTAssertEqual(recorder.items[0].map(\.id), ["q-1", "gift-1", "q-2", "sc-1"])
    }

    func testExactThresholdNotFlooded() async {
        let clock = TestClock()
        let throttler = DanmakuThrottler(clock: clock)
        let recorder = StreamRecorder(throttler.batches)

        for index in 0..<20 {
            await throttler.submit(makeEvent(id: "e-\(index)"))
        }
        await expectSleepers(clock, atLeast: 1)
        clock.advance(by: 1)

        await expectEventually { recorder.items.count == 1 }
        XCTAssertEqual(recorder.items[0].count, 20, "等于阈值不触发洪峰降级")
    }

    func testFloodWithNoHighValueEmitsNothing() async {
        let clock = TestClock()
        let throttler = DanmakuThrottler(
            configuration: .init(floodThreshold: 3), clock: clock
        )
        let recorder = StreamRecorder(throttler.batches)

        for index in 0..<5 {
            await throttler.submit(makeEvent(id: "e-\(index)"))
        }
        await expectSleepers(clock, atLeast: 1)
        clock.advance(by: 1)

        // 空批次不输出、流上不可观察 → 以 pending 清零为屏障确认窗口已结算，
        // 避免下一次 submit 与 flush 竞态折进旧窗口。
        let flushed = await waitUntilAsync { await throttler.pendingCount() == 0 }
        XCTAssertTrue(flushed, "洪峰窗口应已结算")
        XCTAssertTrue(recorder.items.isEmpty, "全部被降级丢弃时不应输出空批次")

        // 后续窗口仍正常工作
        await throttler.submit(makeEvent(id: "after"))
        await expectSleepers(clock, atLeast: 1)
        clock.advance(by: 1)

        await expectEventually { recorder.items.count == 1 }
        XCTAssertEqual(recorder.items.first?.map(\.id), ["after"])
    }

    func testRecentRollingBufferKeepsLastN() async {
        let clock = TestClock()
        let throttler = DanmakuThrottler(clock: clock)
        let recorder = StreamRecorder(throttler.batches)

        for index in 1...4 {
            await throttler.submit(makeEvent(id: "e\(index)"))
        }
        await expectSleepers(clock, atLeast: 1)
        clock.advance(by: 1)
        await expectEventually { recorder.items.count == 1 }

        for index in 5...9 {
            await throttler.submit(makeEvent(id: "e\(index)"))
        }
        await expectSleepers(clock, atLeast: 1)
        clock.advance(by: 1)
        await expectEventually { recorder.items.count == 2 }

        let recent = await throttler.recentEvents()
        XCTAssertEqual(recent.map(\.id), ["e4", "e5", "e6", "e7", "e8", "e9"], "默认保最近 6 条")
    }

    func testShutdownFinishesStreamAndCancelsWindow() async {
        let clock = TestClock()
        let throttler = DanmakuThrottler(clock: clock)
        let recorder = StreamRecorder(throttler.batches)

        await throttler.submit(makeEvent(id: "1"))
        await expectSleepers(clock, atLeast: 1)

        await throttler.shutdown()

        await expectEventually { recorder.finished }
        XCTAssertTrue(recorder.items.isEmpty)
        await expectEventually("窗口任务应被取消") { [clock] in clock.sleeperCount == 0 }
    }
}
