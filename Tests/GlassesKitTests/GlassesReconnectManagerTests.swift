import Foundation
import Testing
import GlassesKit

@Suite("GlassesReconnectManager 退避与重挂编排")
struct GlassesReconnectManagerTests {

    @Test("退避 1s 倍增封顶 30s 且不设次数上限")
    func backoffDoublesAndCapsAt30s() async throws {
        let clock = VirtualClock()
        let mock = MockGlassesSession(clock: clock)
        await mock.simulateBluetoothLoss()   // 不可达 → 每次 start 都失败

        let manager = GlassesReconnectManager(session: mock, clock: clock)
        let events = StreamCollector(manager.events)
        await manager.beginRecovery()

        let expectedDelays: [TimeInterval] = [1, 2, 4, 8, 16, 30, 30]
        for delay in expectedDelays {
            await clock.waitForSleepers(atLeast: 1)
            clock.advance(by: delay)
        }
        // 第 8 次已排程 → 证明前 7 次全部失败且仍在继续（无上限）
        await clock.waitForSleepers(atLeast: 1)

        let scheduled = events.snapshot().compactMap { event -> TimeInterval? in
            if case let .attemptScheduled(_, delay) = event { return delay }
            return nil
        }
        #expect(Array(scheduled.prefix(7)) == expectedDelays)
        #expect(scheduled.count >= 8)

        let failed = events.snapshot().compactMap { event -> Int? in
            if case let .attemptFailed(attempt) = event { return attempt }
            return nil
        }
        #expect(Array(failed.prefix(7)) == [1, 2, 3, 4, 5, 6, 7])

        await manager.stop()
    }

    @Test("恢复后按序重挂 camera → display → 重发最后一屏")
    func recoveryRemountsInOrderAndResendsLastPayload() async throws {
        let clock = VirtualClock()
        let mock = MockGlassesSession(clock: clock)
        let preset = CameraPreset(quality: .medium, frameRate: 24)
        let payload = DisplayPayload(canonicalJSON: #"{"screen":"last"}"#)

        let manager = GlassesReconnectManager(session: mock, clock: clock)
        await manager.recordCameraPreset(preset)
        await manager.recordLastPayload(payload)

        let events = StreamCollector(manager.events)
        await manager.startMonitoring()

        // 故障流触发恢复
        await mock.simulateBluetoothLoss()
        await clock.waitForSleepers(atLeast: 1)

        // 第 1 次尝试前恢复可达；清空日志以便断言纯恢复序列
        await mock.setReachable(true)
        await mock.resetRecords()
        clock.advance(by: 1)

        #expect(await events.waitFor { $0.contains(.recovered(attempts: 1)) })

        let ordered: [ReconnectEvent] = [
            .sessionRestarted(attempt: 1), .cameraReattached, .displayReattached,
            .lastPayloadResent, .recovered(attempts: 1),
        ]
        #expect(events.snapshot().suffix(5) == ordered[...])

        #expect(await mock.operations == [
            .start, .attachCamera(preset), .attachDisplay, .sendDisplayPayload(payload),
        ])
        #expect(await mock.sentPayloads == [payload])

        await manager.stop()
    }

    @Test("未记录过负载时恢复不补发")
    func recoveryWithoutPayloadSkipsResend() async throws {
        let clock = VirtualClock()
        let mock = MockGlassesSession(clock: clock)
        await mock.simulateBluetoothLoss()

        let manager = GlassesReconnectManager(session: mock, clock: clock)
        let events = StreamCollector(manager.events)
        await manager.beginRecovery()

        await clock.waitForSleepers(atLeast: 1)
        await mock.setReachable(true)
        clock.advance(by: 1)

        #expect(await events.waitFor { $0.contains(.recovered(attempts: 1)) })
        #expect(!events.snapshot().contains(.lastPayloadResent))
        #expect(await mock.sentPayloads.isEmpty)

        await manager.stop()
    }

    @Test("恢复进行中重复触发被忽略（幂等）")
    func beginRecoveryIsIdempotentWhileRunning() async throws {
        let clock = VirtualClock()
        let mock = MockGlassesSession(clock: clock)
        await mock.simulateBluetoothLoss()

        let manager = GlassesReconnectManager(session: mock, clock: clock)
        let events = StreamCollector(manager.events)
        await manager.beginRecovery()
        await manager.beginRecovery()
        await manager.beginRecovery()

        await clock.waitForSleepers(atLeast: 1)
        // 只有一条恢复循环 → 只有一个 attempt 1 排程
        let scheduledOnce = events.snapshot().filter {
            if case .attemptScheduled(1, _) = $0 { return true }
            return false
        }
        #expect(scheduledOnce.count == 1)
        #expect(clock.sleeperCount == 1)

        await manager.stop()
    }
}
