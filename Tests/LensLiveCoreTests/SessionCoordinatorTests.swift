// SessionCoordinator 行为验证：开播/停止时序、独立降级、captouch 路由、
// 热降档、系统中断恢复、节流与驻留（虚拟时钟）。
import XCTest
import AudioHub
import DanmakuCore
import GlassRenderer
import GlassesKit
import StreamEngine
@testable import LensLiveCore

final class SessionCoordinatorTests: XCTestCase {

    // MARK: 开播时序（架构 §3.1）

    func testStartSequenceRunsInContractOrder() async throws {
        let h = CoordinatorHarness()
        try await h.coordinator.startLive(configuration: CoordinatorHarness.defaultConfiguration())

        XCTAssertEqual(h.recorder.calls, [
            "glasses.start",
            "glasses.attachCamera(medium)",
            "audio.activate(iphoneMic)",
            "pipeline.start",
            "glasses.attachDisplay",
            "glasses.sendDisplayPayload",
            "danmaku.start",
        ])

        let snapshot = await h.coordinator.currentSnapshot()
        XCTAssertEqual(snapshot.phase, .live)
        XCTAssertEqual(snapshot.readiness.ready, Set(Subsystem.allCases))

        // 首屏 = 空弹幕 + 全部档
        XCTAssertEqual(h.glasses.sentPayloads.count, 1)
        XCTAssertTrue(h.glasses.sentPayloads[0].canonicalJSON.contains("danmaku|all|0"))
    }

    func testGlassesStartFailureAbortsWholeStart() async throws {
        let h = CoordinatorHarness()
        struct Boom: Error {}
        h.glasses.startError = Boom()

        do {
            try await h.coordinator.startLive(configuration: CoordinatorHarness.defaultConfiguration())
            XCTFail("glasses.start 失败应抛错")
        } catch { /* expected */ }

        let snapshot = await h.coordinator.currentSnapshot()
        XCTAssertEqual(snapshot.phase, .idle)
        XCTAssertFalse(h.recorder.contains("pipeline.start"))
        XCTAssertFalse(h.recorder.contains("danmaku.start"))
    }

    // MARK: 停止逆序收尾

    func testStopTearsDownInReverseOrder() async throws {
        let h = CoordinatorHarness()
        try await h.coordinator.startLive(configuration: CoordinatorHarness.defaultConfiguration())
        await h.coordinator.stopLive()

        XCTAssertEqual(Array(h.recorder.calls.suffix(7)), [
            "danmaku.stop",
            "glasses.clearDisplay",
            "glasses.detachDisplay",
            "pipeline.stop",
            "audio.deactivate",
            "glasses.detachCamera",
            "glasses.stop",
        ])
        let snapshot = await h.coordinator.currentSnapshot()
        XCTAssertEqual(snapshot.phase, .idle)
    }

    // MARK: 独立降级 —— 弹幕断连不停推流

    func testDanmakuDisconnectDegradesWithoutStoppingStream() async throws {
        let h = CoordinatorHarness()
        try await h.coordinator.startLive(configuration: CoordinatorHarness.defaultConfiguration())

        h.danmaku.statesCont.yield(.reconnecting(attempt: 1))
        let degraded = try await waitForSnapshot(h.coordinator) {
            $0.phase == .degraded([.danmaku])
        }
        XCTAssertTrue(degraded.notices.contains { $0.notice == .danmakuDisconnected })
        XCTAssertFalse(h.recorder.contains("pipeline.stop"), "弹幕掉线绝不停推流")
        XCTAssertFalse(h.recorder.contains("glasses.stop"))

        h.danmaku.statesCont.yield(.connected)
        let recovered = try await waitForSnapshot(h.coordinator) { $0.phase == .live }
        XCTAssertTrue(recovered.notices.contains { $0.notice == .danmakuRecovered })
    }

    // MARK: 独立降级 —— rtmp 放弃后弹幕仍在

    func testRtmpGiveUpKeepsDanmakuAlive() async throws {
        let h = CoordinatorHarness()
        try await h.coordinator.startLive(configuration: CoordinatorHarness.defaultConfiguration())

        h.pipeline.statesCont.yield(.reconnecting(attempt: 2))
        let reconnecting = try await waitForSnapshot(h.coordinator) {
            $0.phase == .degraded([.rtmp])
        }
        XCTAssertTrue(reconnecting.notices.contains { $0.notice == .rtmpReconnecting(attempt: 2) })

        h.pipeline.statesCont.yield(.failed(reason: "gave up"))
        let gaveUp = try await waitForSnapshot(h.coordinator) { snapshot in
            snapshot.notices.contains { $0.notice == .rtmpGaveUp }
        }
        XCTAssertEqual(gaveUp.phase, .degraded([.rtmp]), "rtmp 放弃仅降级，保会话")
        XCTAssertTrue(gaveUp.readiness.ready.contains(.danmaku), "弹幕链路不受推流故障影响")
        XCTAssertFalse(h.recorder.contains("danmaku.stop"))
        XCTAssertFalse(h.recorder.contains("glasses.stop"))
    }

    // MARK: captouch 三档循环

    func testCaptouchTapCyclesFilterModes() async throws {
        let h = CoordinatorHarness()
        try await h.coordinator.startLive(configuration: CoordinatorHarness.defaultConfiguration())

        h.glasses.captouchCont.yield(.tap)
        _ = try await waitForSnapshot(h.coordinator) { $0.filterMode == .highValueOnly }

        h.glasses.captouchCont.yield(.tap)
        _ = try await waitForSnapshot(h.coordinator) { $0.filterMode == .paused }

        h.glasses.captouchCont.yield(.tap)
        _ = try await waitForSnapshot(h.coordinator) { $0.filterMode == .all }

        // 首屏 + 三次档位切换重绘
        try await waitUntil { h.glasses.sentPayloads.count == 4 }
        let jsons = h.glasses.sentPayloads.map(\.canonicalJSON)
        XCTAssertTrue(jsons[1].contains("danmaku|highValueOnly|"))
        XCTAssertTrue(jsons[2].contains("danmaku|paused|"))
        XCTAssertTrue(jsons[3].contains("danmaku|all|"))
    }

    // MARK: backOnRoot → 需要用户确认，不直接停

    func testBackOnRootRequestsConfirmationWithoutStopping() async throws {
        let h = CoordinatorHarness()
        try await h.coordinator.startLive(configuration: CoordinatorHarness.defaultConfiguration())

        h.glasses.captouchCont.yield(.backOnRoot)
        let snapshot = try await waitForSnapshot(h.coordinator) { $0.awaitingEndConfirmation }
        XCTAssertEqual(snapshot.phase, .live, "back 手势只发确认请求，会话不变")
        XCTAssertFalse(h.recorder.contains("pipeline.stop"))
        XCTAssertFalse(h.recorder.contains("glasses.stop"))

        // 用户取消 → 标志复位
        await h.coordinator.cancelEndRequest()
        let cancelled = await h.coordinator.currentSnapshot()
        XCTAssertFalse(cancelled.awaitingEndConfirmation)

        // 再次请求并确认 → 完整停止
        h.glasses.captouchCont.yield(.backOnRoot)
        _ = try await waitForSnapshot(h.coordinator) { $0.awaitingEndConfirmation }
        await h.coordinator.confirmEndAndStop()
        let ended = await h.coordinator.currentSnapshot()
        XCTAssertEqual(ended.phase, .idle)
        XCTAssertTrue(h.recorder.contains("glasses.stop"))
    }

    // MARK: 热警 → 通知 + 自动降档

    func testThermalHotTriggersDowngrade() async throws {
        let h = CoordinatorHarness()
        try await h.coordinator.startLive(configuration: CoordinatorHarness.defaultConfiguration())

        h.glasses.faultsCont.yield(.thermal(.hot))
        let expectedPreset = CameraPreset(quality: .low, frameRate: 24)
        let snapshot = try await waitForSnapshot(h.coordinator) { snap in
            snap.notices.contains { $0.notice == .thermalWarning(.hot, degradedTo: expectedPreset) }
        }
        XCTAssertEqual(snapshot.glassesHealth.thermal, .hot)

        try await waitUntil { h.recorder.contains("glasses.attachCamera(low)") }
        let after = try await waitForSnapshot(h.coordinator) { $0.cameraPreset.quality == .low }
        XCTAssertEqual(after.cameraPreset.frameRate, 24)
        // 眼镜端收到告警卡
        try await waitUntil {
            h.glasses.sentPayloads.contains { $0.canonicalJSON.contains("alert|low") }
        }
    }

    // MARK: 音源回退通知

    func testAudioFallbackEmitsNotice() async throws {
        let h = CoordinatorHarness()
        h.audio.activateResultOverride = .iphoneMic   // HFP 激活被 AudioHub 回退
        try await h.coordinator.startLive(
            configuration: CoordinatorHarness.defaultConfiguration(audioSource: .glassesHFP))

        h.audio.statesCont.yield(.fallback(from: .glassesHFP, to: .iphoneMic, reason: "HFP 稳定期校验失败"))
        let snapshot = try await waitForSnapshot(h.coordinator) { snap in
            snap.notices.contains { $0.notice == .audioFallback(from: .glassesHFP, to: .iphoneMic) }
        }
        XCTAssertEqual(snapshot.audioSource, .iphoneMic)
        XCTAssertEqual(snapshot.phase, .live, "音源回退成功不降级")
    }

    // MARK: 系统中断 → interrupted → resuming → live

    func testSystemInterruptionThenResume() async throws {
        let h = CoordinatorHarness()
        try await h.coordinator.startLive(configuration: CoordinatorHarness.defaultConfiguration())

        h.glasses.faultsCont.yield(.systemInterrupted)
        let interrupted = try await waitForSnapshot(h.coordinator) { $0.phase == .interrupted }
        XCTAssertTrue(interrupted.notices.contains { $0.notice == .interruptedBySystem })

        h.glasses.sessionCont.yield(.started)
        let resumed = try await waitForSnapshot(h.coordinator) { $0.phase == .live }
        XCTAssertTrue(resumed.notices.contains { $0.notice == .resumed })
    }

    // MARK: 蓝牙断连 → 降级（不停推流）→ 恢复重发最后一屏

    func testBluetoothLossDegradesThenRecoveryResendsLastScreen() async throws {
        let h = CoordinatorHarness()
        try await h.coordinator.startLive(configuration: CoordinatorHarness.defaultConfiguration())
        let sentBefore = h.glasses.sentPayloads.count

        h.glasses.faultsCont.yield(.bluetoothLost)
        let lost = try await waitForSnapshot(h.coordinator) { $0.phase == .degraded([.glasses]) }
        XCTAssertTrue(lost.notices.contains { $0.notice == .bluetoothLost })
        XCTAssertFalse(h.recorder.contains("pipeline.stop"), "蓝牙断连交给重连，不停推流")

        h.glasses.sessionCont.yield(.started)
        let recovered = try await waitForSnapshot(h.coordinator) { $0.phase == .live }
        XCTAssertTrue(recovered.notices.contains { $0.notice == .bluetoothRecovered })

        // 恢复后重发最后一屏（内容与断前最后一屏一致）
        try await waitUntil { h.glasses.sentPayloads.count == sentBefore + 1 }
        XCTAssertEqual(h.glasses.sentPayloads.last, h.glasses.sentPayloads[sentBefore - 1])
    }

    // MARK: 弹幕上屏节流（虚拟时钟）

    func testDanmakuEventIsThrottledBeforeDisplayRefresh() async throws {
        let h = CoordinatorHarness()
        try await h.coordinator.startLive(configuration: CoordinatorHarness.defaultConfiguration())
        XCTAssertEqual(h.glasses.sentPayloads.count, 1)

        h.danmaku.eventsCont.yield(h.chatEvent(id: "c1"))
        _ = try await waitForSnapshot(h.coordinator) { $0.danmakuBuffer.count == 1 }
        XCTAssertEqual(h.glasses.sentPayloads.count, 1, "普通弹幕不应即时上屏，须等节流窗口")

        // 等 ticker + throttle 两个睡眠者就位，再推进 1s
        try await waitUntil { h.clock.sleeperCount >= 2 }
        h.clock.advance(by: 1)

        try await waitUntil { h.glasses.sentPayloads.count == 2 }
        XCTAssertTrue(h.glasses.sentPayloads[1].canonicalJSON.contains("danmaku|all|1"))
    }

    // MARK: 高价值卡：即时上屏 + 驻留期不被普通刷新覆盖 + 到期回落

    func testHighValueCardBypassesThrottleAndDwells() async throws {
        let h = CoordinatorHarness()
        try await h.coordinator.startLive(configuration: CoordinatorHarness.defaultConfiguration())

        h.danmaku.eventsCont.yield(h.superChatEvent(id: "sc1"))
        try await waitUntil { h.glasses.sentPayloads.count == 2 }
        XCTAssertTrue(h.glasses.sentPayloads[1].canonicalJSON.contains("card|sc1"), "高价值卡绕过节流即时上屏")

        // 驻留期内普通弹幕的节流刷新不得覆盖卡片
        h.danmaku.eventsCont.yield(h.chatEvent(id: "c2"))
        _ = try await waitForSnapshot(h.coordinator) { $0.danmakuBuffer.count == 2 }
        try await waitUntil { h.clock.sleeperCount >= 3 }   // ticker + dwell + throttle
        h.clock.advance(by: 1)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(h.glasses.sentPayloads.count, 2, "驻留期间普通刷新不覆盖卡片")

        // 驻留 8s 到期 → 回落普通弹幕屏（含 sc1 + c2 两条）
        h.clock.advance(by: 8)
        try await waitUntil { h.glasses.sentPayloads.count == 3 }
        XCTAssertTrue(h.glasses.sentPayloads[2].canonicalJSON.contains("danmaku|all|2"))
    }

    // MARK: 驻留期 tap = 已读（不切档）

    func testTapDuringDwellMarksReadWithoutCyclingMode() async throws {
        let h = CoordinatorHarness()
        try await h.coordinator.startLive(configuration: CoordinatorHarness.defaultConfiguration())

        h.danmaku.eventsCont.yield(h.superChatEvent(id: "sc9"))
        try await waitUntil { h.glasses.sentPayloads.count == 2 }

        h.glasses.captouchCont.yield(.tap)
        try await waitUntil { h.glasses.sentPayloads.count == 3 }
        XCTAssertTrue(h.glasses.sentPayloads[2].canonicalJSON.contains("danmaku|all|1"),
                      "tap 已读后回落普通屏")
        let snapshot = await h.coordinator.currentSnapshot()
        XCTAssertEqual(snapshot.filterMode, .all, "已读语义不切档")
    }

    // MARK: 纯推流模式（danmaku 不计入就绪位图）

    func testDanmakuDisabledSessionGoesLiveWithoutConnector() async throws {
        let h = CoordinatorHarness()
        try await h.coordinator.startLive(
            configuration: CoordinatorHarness.defaultConfiguration(danmakuEnabled: false))

        let snapshot = await h.coordinator.currentSnapshot()
        XCTAssertEqual(snapshot.phase, .live)
        XCTAssertFalse(h.recorder.contains("danmaku.start"))

        await h.coordinator.stopLive()
        XCTAssertFalse(h.recorder.contains("danmaku.stop"))
    }
}
