import Foundation
import Testing
@testable import StreamEngine

@Suite("StreamSessionController")
struct StreamSessionControllerTests {
    private static let target = RTMPTarget.twitch(streamKeyRef: "kc-ref")

    /// 连接成功：start → connecting → streaming
    @Test func startReachesStreaming() async {
        let pipeline = MockPipeline()
        let controller = StreamSessionController(pipeline: pipeline, clock: TestStreamClock())
        let states = Recorder(controller.states)

        await controller.start(target: Self.target, streamKey: "secret")

        #expect(await waitUntil { await controller.currentState == .streaming })
        #expect(await waitUntil { states.snapshot == [.connecting, .streaming] })
        #expect(pipeline.startCalls.count == 1)
        #expect(pipeline.startCalls[0].key == "secret")
        #expect(pipeline.startCalls[0].target == Self.target)
    }

    /// 幂等：会话进行中重复 start 被忽略
    @Test func duplicateStartIsIgnored() async {
        let pipeline = MockPipeline()
        let controller = StreamSessionController(pipeline: pipeline, clock: TestStreamClock())
        let states = Recorder(controller.states)

        await controller.start(target: Self.target, streamKey: "secret")
        #expect(await waitUntil { await controller.currentState == .streaming })
        await controller.start(target: Self.target, streamKey: "other")

        #expect(pipeline.startCalls.count == 1)
        #expect(await waitUntil { states.snapshot == [.connecting, .streaming] })
    }

    /// 断流后按 1,2,4 退避重连，第 3 次成功恢复 streaming
    @Test func reconnectSucceedsOnThirdAttempt() async {
        let pipeline = MockPipeline()
        let clock = TestStreamClock()
        let controller = StreamSessionController(pipeline: pipeline, clock: clock)
        let states = Recorder(controller.states)
        let notices = Recorder(controller.notices)

        pipeline.script([.succeed, .fail("拒绝 1"), .fail("拒绝 2"), .succeed])
        await controller.start(target: Self.target, streamKey: "secret")
        #expect(await waitUntil { await controller.currentState == .streaming })

        pipeline.emitState(.failed(reason: "网络断开"))

        #expect(await waitUntil {
            await controller.currentState == .streaming && clock.sleeps.count == 3
        })
        #expect(clock.sleeps == [1, 2, 4])
        #expect(pipeline.startCalls.count == 4)
        #expect(await waitUntil {
            states.snapshot == [
                .connecting, .streaming,
                .reconnecting(attempt: 1), .reconnecting(attempt: 2), .reconnecting(attempt: 3),
                .streaming,
            ]
        })
        #expect(await waitUntil {
            notices.snapshot == [
                .reconnecting(attempt: 1), .reconnecting(attempt: 2), .reconnecting(attempt: 3),
            ]
        })
    }

    /// 重连 5 次全部失败 → gaveUp 通知 + failed 终态
    @Test func reconnectGivesUpAfterFiveAttempts() async {
        let pipeline = MockPipeline()
        let clock = TestStreamClock()
        let controller = StreamSessionController(pipeline: pipeline, clock: clock)
        let states = Recorder(controller.states)
        let notices = Recorder(controller.notices)

        pipeline.script([.succeed], fallback: .fail("连接被拒"))
        await controller.start(target: Self.target, streamKey: "secret")
        #expect(await waitUntil { await controller.currentState == .streaming })

        pipeline.emitState(.failed(reason: "网络断开"))

        #expect(await waitUntil { await controller.currentState == .failed(reason: "连接被拒") })
        #expect(clock.sleeps == [1, 2, 4, 8, 16])
        #expect(pipeline.startCalls.count == 6) // 首次 + 5 次重试
        #expect(await waitUntil {
            states.snapshot == [
                .connecting, .streaming,
                .reconnecting(attempt: 1), .reconnecting(attempt: 2), .reconnecting(attempt: 3),
                .reconnecting(attempt: 4), .reconnecting(attempt: 5),
                .failed(reason: "连接被拒"),
            ]
        })
        #expect(await waitUntil {
            notices.snapshot == [
                .reconnecting(attempt: 1), .reconnecting(attempt: 2), .reconnecting(attempt: 3),
                .reconnecting(attempt: 4), .reconnecting(attempt: 5),
                .gaveUp,
            ]
        })
    }

    /// stop 幂等：重复 stop 不重复发状态；stopped 后可重新 start
    @Test func stopIsIdempotentAndAllowsRestart() async {
        let pipeline = MockPipeline()
        let controller = StreamSessionController(pipeline: pipeline, clock: TestStreamClock())
        let states = Recorder(controller.states)

        await controller.start(target: Self.target, streamKey: "secret")
        #expect(await waitUntil { await controller.currentState == .streaming })

        await controller.stop()
        await controller.stop()
        #expect(await controller.currentState == .stopped)
        #expect(await waitUntil { states.snapshot == [.connecting, .streaming, .stopped] })
        #expect(pipeline.stopCount == 2)

        // stopped 后允许重新开播
        await controller.start(target: Self.target, streamKey: "secret")
        #expect(await waitUntil { await controller.currentState == .streaming })
        #expect(await waitUntil {
            states.snapshot == [.connecting, .streaming, .stopped, .connecting, .streaming]
        })
    }

    /// stop 任何态可达：未 start 直接 stop 也进入 stopped
    @Test func stopFromIdleReachesStopped() async {
        let pipeline = MockPipeline()
        let controller = StreamSessionController(pipeline: pipeline, clock: TestStreamClock())
        let states = Recorder(controller.states)

        await controller.stop()

        #expect(await controller.currentState == .stopped)
        #expect(await waitUntil { states.snapshot == [.stopped] })
    }

    /// 首次连接即失败也走重连管道
    @Test func initialConnectFailureEntersReconnect() async {
        let pipeline = MockPipeline()
        let clock = TestStreamClock()
        let controller = StreamSessionController(pipeline: pipeline, clock: clock)
        let notices = Recorder(controller.notices)

        pipeline.script([.fail("首连失败"), .succeed])
        await controller.start(target: Self.target, streamKey: "secret")

        #expect(await waitUntil { await controller.currentState == .streaming })
        #expect(clock.sleeps == [1])
        #expect(await waitUntil { notices.snapshot == [.reconnecting(attempt: 1)] })
    }

    /// stats 原样转发管线统计
    @Test func statsAreForwarded() async {
        let pipeline = MockPipeline()
        let controller = StreamSessionController(pipeline: pipeline, clock: TestStreamClock())
        let stats = Recorder(controller.stats)

        await controller.start(target: Self.target, streamKey: "secret")
        #expect(await waitUntil { await controller.currentState == .streaming })

        let sample = StreamStats(bitrateMbps: 4.2, fps: 29.5, droppedFrameRatio: 0.01, networkGood: true)
        pipeline.emitStats(sample)

        #expect(await waitUntil { stats.snapshot == [sample] })
    }
}
