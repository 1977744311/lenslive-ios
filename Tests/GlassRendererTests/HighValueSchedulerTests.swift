import Foundation
import Testing
import GlassRenderer
import DanmakuCore

@Suite("HighValueScheduler 驻留调度")
struct HighValueSchedulerTests {

    @Test("单卡驻留 8s 后回落弹幕屏")
    func dwellThenFallback() async throws {
        let clock = VirtualClock()
        let scheduler = HighValueScheduler(dwell: 8, clock: clock)
        let intents = StreamCollector(scheduler.intents)

        #expect(await intents.waitFor { $0.first == .danmaku })   // 基线意图

        let sc = superChatEvent(id: "sc1", user: "山高月小", text: "延迟多少？", value: 50)
        await scheduler.submit(sc)
        #expect(await intents.waitFor { $0.last == .highValueCard(event: sc, remaining: 8) })

        await clock.waitForSleepers(atLeast: 1)
        clock.advance(by: 8)
        #expect(await intents.waitFor { $0.last == .danmaku })
        #expect(intents.snapshot() == [.danmaku, .highValueCard(event: sc, remaining: 8), .danmaku])
    }

    @Test("驻留中再来高价值 → 排队顺延，每卡足秒")
    func queuedHighValueExtendsSequentially() async throws {
        let clock = VirtualClock()
        let scheduler = HighValueScheduler(dwell: 8, clock: clock)
        let intents = StreamCollector(scheduler.intents)

        let sc1 = superChatEvent(id: "sc1", user: "a", text: "第一条", value: 50)
        let sc2 = superChatEvent(id: "sc2", user: "b", text: "第二条", value: 100)

        await scheduler.submit(sc1)
        #expect(await intents.waitFor { $0.last == .highValueCard(event: sc1, remaining: 8) })

        await scheduler.submit(sc2)   // 驻留中到达 → 排队，不打断当前卡
        #expect(intents.snapshot().last == .highValueCard(event: sc1, remaining: 8))

        await clock.waitForSleepers(atLeast: 1)
        clock.advance(by: 8)
        #expect(await intents.waitFor { $0.last == .highValueCard(event: sc2, remaining: 8) })

        await clock.waitForSleepers(atLeast: 1)
        clock.advance(by: 8)
        #expect(await intents.waitFor { $0.last == .danmaku })

        #expect(intents.snapshot() == [
            .danmaku,
            .highValueCard(event: sc1, remaining: 8),
            .highValueCard(event: sc2, remaining: 8),
            .danmaku,
        ])
    }

    @Test("驻留期普通事件不打断卡片（非高价值直接忽略）")
    func ordinaryEventsDoNotInterruptDwell() async throws {
        let clock = VirtualClock()
        let scheduler = HighValueScheduler(dwell: 8, clock: clock)
        let intents = StreamCollector(scheduler.intents)

        let sc = superChatEvent(id: "sc1", user: "a", text: "SC", value: 30)
        await scheduler.submit(sc)
        #expect(await intents.waitFor { $0.last == .highValueCard(event: sc, remaining: 8) })

        let countBefore = intents.count
        await scheduler.submit(chatEvent(id: "c1", user: "路人", text: "普通弹幕"))
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(intents.count == countBefore)   // 意图未变

        await clock.waitForSleepers(atLeast: 1)
        clock.advance(by: 8)
        #expect(await intents.waitFor { $0.last == .danmaku })
    }

    @Test("dwell 可配置")
    func dwellIsConfigurable() async throws {
        let clock = VirtualClock()
        let scheduler = HighValueScheduler(dwell: 3, clock: clock)
        let intents = StreamCollector(scheduler.intents)

        let sc = superChatEvent(id: "sc1", user: "a", text: "短驻留", value: 10)
        await scheduler.submit(sc)
        #expect(await intents.waitFor { $0.last == .highValueCard(event: sc, remaining: 3) })

        await clock.waitForSleepers(atLeast: 1)
        clock.advance(by: 3)
        #expect(await intents.waitFor { $0.last == .danmaku })
    }
}
