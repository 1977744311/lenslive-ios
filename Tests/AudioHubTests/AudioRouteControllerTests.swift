import Foundation
import Testing
@testable import AudioHub

@Suite("AudioRouteController")
struct AudioRouteControllerTests {
    /// HFP 成功路径：configuring → settling(2s) → verify → active(HFP)，稳定窗口精确计时一次
    @Test func hfpHappyPathSettlesThenActivates() async {
        let ports = MockPorts()
        let clock = TestAudioClock()
        let controller = AudioRouteController(ports: ports, clock: clock)
        let states = Recorder(controller.states)

        let result = await controller.activate(.glassesHFP)

        #expect(result == .glassesHFP)
        #expect(await controller.currentSource == .glassesHFP)
        #expect(clock.sleeps == [2.0]) // settling 稳定窗口恰好等待 2s
        #expect(await waitUntil { states.snapshot.count == 3 })
        #expect(states.snapshot == [
            .configuring,
            .settling(remaining: 2.0),
            .active(.glassesHFP),
        ])
        #expect(ports.calls == ["teardown", "configure:glassesHFP", "verify:glassesHFP"])
    }

    /// verify 失败 → 发 fallback 并自动激活 iPhone 麦
    @Test func hfpVerifyFailureFallsBackToIphoneMic() async {
        let ports = MockPorts()
        ports.answerVerify(for: .glassesHFP, with: false)
        let controller = AudioRouteController(ports: ports, clock: TestAudioClock())
        let states = Recorder(controller.states)

        let result = await controller.activate(.glassesHFP)

        #expect(result == .iphoneMic)
        #expect(await controller.currentSource == .iphoneMic)
        #expect(await waitUntil { states.snapshot.count == 4 })
        let snapshot = states.snapshot
        #expect(snapshot[0] == .configuring)
        #expect(snapshot[1] == .settling(remaining: 2.0))
        if case .fallback(let from, let to, _) = snapshot[2] {
            #expect(from == .glassesHFP)
            #expect(to == .iphoneMic)
        } else {
            Issue.record("第三个状态应为 fallback，实际是 \(snapshot[2])")
        }
        #expect(snapshot[3] == .active(.iphoneMic))
        // 回退先清掉半配置的 HFP 路由再建 iPhone 麦路由
        #expect(ports.calls == [
            "teardown", "configure:glassesHFP", "verify:glassesHFP",
            "teardown", "configure:iphoneMic",
        ])
    }

    /// HFP 配置抛错（如可用输入无 HFP 端口）→ 不进入 settling，直接回退
    @Test func hfpConfigureFailureFallsBackWithoutSettling() async {
        let ports = MockPorts()
        ports.failConfigure(for: .glassesHFP, message: "蓝牙不可用")
        let clock = TestAudioClock()
        let controller = AudioRouteController(ports: ports, clock: clock)
        let states = Recorder(controller.states)

        let result = await controller.activate(.glassesHFP)

        #expect(result == .iphoneMic)
        #expect(clock.sleeps.isEmpty)
        #expect(await waitUntil { states.snapshot.count == 3 })
        let snapshot = states.snapshot
        #expect(snapshot[0] == .configuring)
        if case .fallback(let from, let to, let reason) = snapshot[1] {
            #expect(from == .glassesHFP)
            #expect(to == .iphoneMic)
            #expect(reason.contains("蓝牙不可用"))
        } else {
            Issue.record("第二个状态应为 fallback，实际是 \(snapshot[1])")
        }
        #expect(snapshot[2] == .active(.iphoneMic))
    }

    /// 切换语义：先停旧再起新，虚拟时钟总耗时 ≤2s（唯一等待就是 HFP 的 2s 稳定窗口）
    @Test func switchingCompletesWithinTwoSeconds() async {
        let ports = MockPorts()
        let clock = TestAudioClock()
        let controller = AudioRouteController(ports: ports, clock: clock)

        await controller.activate(.glassesHFP)
        #expect(clock.totalSlept <= 2.0)

        let beforeSwitch = clock.totalSlept
        await controller.activate(.iphoneMic)
        // HFP → iPhone 麦：无 settling，无额外等待
        #expect(clock.totalSlept - beforeSwitch <= 0.0001)
        #expect(await controller.currentSource == .iphoneMic)
        // 先 teardown 旧 HFP 路由，再配置新路由
        #expect(ports.calls.suffix(2) == ["teardown", "configure:iphoneMic"])
    }

    /// muted：无系统路由，直接 active
    @Test func mutedActivatesImmediately() async {
        let ports = MockPorts()
        let clock = TestAudioClock()
        let controller = AudioRouteController(ports: ports, clock: clock)
        let states = Recorder(controller.states)

        let result = await controller.activate(.muted)

        #expect(result == .muted)
        #expect(await controller.currentSource == .muted)
        #expect(clock.sleeps.isEmpty)
        #expect(await waitUntil { states.snapshot.count == 2 })
        #expect(states.snapshot == [.configuring, .active(.muted)])
        // 只停旧路由，不做任何 configure/verify
        #expect(ports.calls == ["teardown"])
    }

    /// deactivate：停用路由并回 inactive
    @Test func deactivateTearsDownAndGoesInactive() async {
        let ports = MockPorts()
        let controller = AudioRouteController(ports: ports, clock: TestAudioClock())
        let states = Recorder(controller.states)

        await controller.activate(.iphoneMic)
        await controller.deactivate()

        #expect(await waitUntil { states.snapshot.last == .inactive })
        #expect(ports.calls == ["teardown", "configure:iphoneMic", "teardown"])
    }

    /// iPhone 麦也失败（回退终点失效）→ failed 并保底 muted
    @Test func iphoneMicFailureEndsInMuted() async {
        let ports = MockPorts()
        ports.answerVerify(for: .glassesHFP, with: false)
        ports.failConfigure(for: .iphoneMic, message: "会话被占用")
        let controller = AudioRouteController(ports: ports, clock: TestAudioClock())
        let states = Recorder(controller.states)

        let result = await controller.activate(.glassesHFP)

        #expect(result == .muted)
        #expect(await controller.currentSource == .muted)
        #expect(await waitUntil {
            if case .failed = states.snapshot.last { return true }
            return false
        })
    }
}
