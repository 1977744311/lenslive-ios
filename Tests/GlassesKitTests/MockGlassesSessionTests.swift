import Foundation
import Testing
import GlassesKit

@Suite("MockGlassesSession 脚本化状态流")
struct MockGlassesSessionTests {

    @Test("start 产生 starting → started 生命周期")
    func startEmitsLifecycle() async throws {
        let mock = MockGlassesSession()
        let states = StreamCollector(mock.sessionStates)
        try await mock.start()
        #expect(await states.waitFor { $0 == [.starting, .started] })
        #expect(await mock.operations == [.start])
    }

    @Test("attach/detach display 生命周期与负载记录")
    func displayLifecycleAndPayloadHistory() async throws {
        let mock = MockGlassesSession()
        try await mock.start()

        // display 未挂载时发送 → displayNotAttached
        await #expect(throws: GlassesSessionError.displayNotAttached) {
            try await mock.sendDisplayPayload(DisplayPayload(canonicalJSON: "{}"))
        }

        let displayStates = StreamCollector(mock.displayStates)
        try await mock.attachDisplay()
        #expect(await displayStates.waitFor { $0.suffix(2) == [.starting, .started] })

        let a = DisplayPayload(canonicalJSON: #"{"screen":"a"}"#)
        let b = DisplayPayload(canonicalJSON: #"{"screen":"b"}"#)
        try await mock.sendDisplayPayload(a)
        try await mock.sendDisplayPayload(b)
        #expect(await mock.sentPayloads == [a, b])
        #expect(await mock.lastPayload == b)

        await mock.detachDisplay()
        #expect(await mock.currentDisplayState == .stopped)
    }

    @Test("相机帧节拍器按 preset.frameRate 用注入时钟产帧")
    func cameraMetronomeFollowsFrameRate() async throws {
        let clock = VirtualClock()
        let mock = MockGlassesSession(clock: clock)
        let frames = StreamCollector(mock.cameraFrames)

        try await mock.start()
        try await mock.attachCamera(preset: CameraPreset(quality: .low, frameRate: 2))   // 0.5s/帧

        for _ in 0..<3 {
            await clock.waitForSleepers(atLeast: 1)
            clock.advance(by: 0.5)
        }
        #expect(await frames.waitFor { $0.count >= 3 })

        let collected = frames.snapshot()
        #expect(collected.prefix(3).map(\.sequence) == [1, 2, 3])
        #expect(collected.prefix(3).map { $0.timestamp.timeIntervalSince1970 } == [0.5, 1.0, 1.5])

        // detach 后节拍器停止：虚拟时钟上不再有挂起的 sleeper
        await mock.detachCamera()
        await clock.waitForSleepersDrained()
        #expect(clock.sleeperCount == 0)
        #expect(await mock.currentCameraState == .stopped)
    }

    @Test("蓝牙断连剧本：fault + 状态归零 + 后续调用被拒")
    func bluetoothLossScript() async throws {
        let mock = MockGlassesSession()
        let faults = StreamCollector(mock.faults)
        try await mock.start()
        try await mock.attachDisplay()

        await mock.simulateBluetoothLoss()

        #expect(await faults.waitFor { $0.contains(.bluetoothLost) })
        #expect(await mock.currentSessionState == .stopped)
        #expect(await mock.currentDisplayState == .stopped)

        await #expect(throws: GlassesSessionError.notConnected) { try await mock.start() }
        await #expect(throws: GlassesSessionError.notConnected) {
            try await mock.sendDisplayPayload(DisplayPayload(canonicalJSON: "{}"))
        }

        // 恢复可达后可正常重连
        await mock.setReachable(true)
        try await mock.start()
        #expect(await mock.currentSessionState == .started)
    }

    @Test("captouch 手势注入直达订阅方")
    func captouchInjection() async throws {
        let mock = MockGlassesSession()
        let gestures = StreamCollector(mock.captouch)
        await mock.injectGesture(.tap)
        await mock.injectGesture(.backOnRoot)
        #expect(await gestures.waitFor { $0 == [.tap, .backOnRoot] })
    }

    @Test("热等级与任意状态注入")
    func thermalAndStateInjection() async throws {
        let mock = MockGlassesSession()
        let thermal = StreamCollector(mock.thermal)
        let camera = StreamCollector(mock.cameraStates)

        await mock.injectThermal(.warm)
        await mock.injectThermal(.hot)
        await mock.injectCameraState(.waitingForDevice)

        #expect(await thermal.waitFor { $0 == [.warm, .hot] })
        #expect(await camera.waitFor { $0 == [.waitingForDevice] })
    }
}
