// 六路协议的可脚本化假实现 + 虚拟时钟 + 全局调用顺序记录。
// 全部为测试 target 私有；线程安全经 NSLock（Swift 6 严格并发下以 @unchecked Sendable 承诺）。
import Foundation
import AudioHub
import DanmakuCore
import GlassRenderer
import GlassesKit
import StreamEngine
@testable import LensLiveCore

// MARK: - 调用顺序记录（跨 mock 共享，锁保护，同步记录保证顺序可断言）

final class CallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func record(_ call: String) {
        lock.lock(); defer { lock.unlock() }
        storage.append(call)
    }

    var calls: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func firstIndex(of call: String) -> Int? { calls.firstIndex(of: call) }
    func contains(_ call: String) -> Bool { calls.contains(call) }
}

// MARK: - 虚拟时钟（多睡眠者、支持取消；advance 唤醒到期者）

final class VirtualClock: Clock_, @unchecked Sendable {
    private struct Sleeper {
        let id: UUID
        let deadline: Date
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var currentTime = Date(timeIntervalSince1970: 1_000_000)
    private var sleepers: [Sleeper] = []
    private var cancelledBeforeRegistration: Set<UUID> = []

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return currentTime
    }

    var sleeperCount: Int {
        lock.lock(); defer { lock.unlock() }
        return sleepers.count
    }

    func sleep(seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let registered = lock.withLock { () -> Bool in
                    if cancelledBeforeRegistration.remove(id) != nil { return false }
                    let deadline = currentTime.addingTimeInterval(seconds)
                    sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return true
                }
                if !registered { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                if let index = sleepers.firstIndex(where: { $0.id == id }) {
                    return sleepers.remove(at: index).continuation
                }
                cancelledBeforeRegistration.insert(id)
                return nil
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func advance(by seconds: TimeInterval) {
        let due = lock.withLock { () -> [Sleeper] in
            currentTime = currentTime.addingTimeInterval(seconds)
            let ready = sleepers
                .filter { $0.deadline <= currentTime }
                .sorted { $0.deadline < $1.deadline }
            sleepers.removeAll { $0.deadline <= currentTime }
            return ready
        }
        due.forEach { $0.continuation.resume() }
    }
}

// MARK: - MockGlasses

final class MockGlasses: GlassesSessionProviding, @unchecked Sendable {
    private let recorder: CallRecorder
    private let lock = NSLock()

    let sessionStates: AsyncStream<GlassesSessionState>
    let sessionCont: AsyncStream<GlassesSessionState>.Continuation
    let displayStates: AsyncStream<DisplayState>
    let displayCont: AsyncStream<DisplayState>.Continuation
    let cameraStates: AsyncStream<CameraStreamState>
    let cameraCont: AsyncStream<CameraStreamState>.Continuation
    let thermal: AsyncStream<ThermalLevel>
    let thermalCont: AsyncStream<ThermalLevel>.Continuation
    let faults: AsyncStream<GlassesFault>
    let faultsCont: AsyncStream<GlassesFault>.Continuation
    let captouch: AsyncStream<CaptouchGesture>
    let captouchCont: AsyncStream<CaptouchGesture>.Continuation
    let cameraFrames: AsyncStream<CameraFramePacket>
    let framesCont: AsyncStream<CameraFramePacket>.Continuation

    var startError: Error?
    var attachCameraError: Error?
    var attachDisplayError: Error?
    var sendPayloadError: Error?

    private var _sentPayloads: [DisplayPayload] = []
    var sentPayloads: [DisplayPayload] {
        lock.lock(); defer { lock.unlock() }
        return _sentPayloads
    }

    init(recorder: CallRecorder) {
        self.recorder = recorder
        (sessionStates, sessionCont) = AsyncStream.makeStream(of: GlassesSessionState.self)
        (displayStates, displayCont) = AsyncStream.makeStream(of: DisplayState.self)
        (cameraStates, cameraCont) = AsyncStream.makeStream(of: CameraStreamState.self)
        (thermal, thermalCont) = AsyncStream.makeStream(of: ThermalLevel.self)
        (faults, faultsCont) = AsyncStream.makeStream(of: GlassesFault.self)
        (captouch, captouchCont) = AsyncStream.makeStream(of: CaptouchGesture.self)
        (cameraFrames, framesCont) = AsyncStream.makeStream(of: CameraFramePacket.self)
    }

    func start() async throws {
        recorder.record("glasses.start")
        if let error = startError { throw error }
    }

    func stop() async { recorder.record("glasses.stop") }

    func attachCamera(preset: CameraPreset) async throws {
        recorder.record("glasses.attachCamera(\(preset.quality.rawValue))")
        if let error = attachCameraError { throw error }
    }

    func detachCamera() async { recorder.record("glasses.detachCamera") }

    func attachDisplay() async throws {
        recorder.record("glasses.attachDisplay")
        if let error = attachDisplayError { throw error }
    }

    func detachDisplay() async { recorder.record("glasses.detachDisplay") }

    func sendDisplayPayload(_ payload: DisplayPayload) async throws {
        recorder.record("glasses.sendDisplayPayload")
        if let error = sendPayloadError { throw error }
        lock.withLock { _sentPayloads.append(payload) }
    }

    func clearDisplay() async throws { recorder.record("glasses.clearDisplay") }
}

// MARK: - MockPipeline

final class MockPipeline: StreamPipelining, @unchecked Sendable {
    private let recorder: CallRecorder
    private let lock = NSLock()

    let states: AsyncStream<StreamPipelineState>
    let statesCont: AsyncStream<StreamPipelineState>.Continuation
    let stats: AsyncStream<StreamStats>
    let statsCont: AsyncStream<StreamStats>.Continuation

    var startError: Error?

    private var _appendedCount = 0
    var appendedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _appendedCount
    }

    init(recorder: CallRecorder) {
        self.recorder = recorder
        (states, statesCont) = AsyncStream.makeStream(of: StreamPipelineState.self)
        (stats, statsCont) = AsyncStream.makeStream(of: StreamStats.self)
    }

    func start(target: RTMPTarget, streamKey: String) async throws {
        recorder.record("pipeline.start")
        if let error = startError { throw error }
    }

    func stop() async { recorder.record("pipeline.stop") }

    func appendVideoPayload(_ payload: any Sendable, timestampSeconds: Double) async {
        lock.withLock { _appendedCount += 1 }
    }
}

// MARK: - MockAudio

final class MockAudio: AudioRouting, @unchecked Sendable {
    private let recorder: CallRecorder

    let states: AsyncStream<AudioRouteState>
    let statesCont: AsyncStream<AudioRouteState>.Continuation

    /// 脚本：activate 的返回值覆盖（nil = 原样返回请求源）
    var activateResultOverride: AudioSource?
    private let lock = NSLock()
    private var _current: AudioSource = .iphoneMic

    var currentSource: AudioSource {
        get async { lock.withLock { _current } }
    }

    init(recorder: CallRecorder) {
        self.recorder = recorder
        (states, statesCont) = AsyncStream.makeStream(of: AudioRouteState.self)
    }

    @discardableResult
    func activate(_ source: AudioSource) async -> AudioSource {
        recorder.record("audio.activate(\(source.rawValue))")
        let effective = activateResultOverride ?? source
        lock.withLock { _current = effective }
        return effective
    }

    func deactivate() async { recorder.record("audio.deactivate") }
}

// MARK: - MockDanmaku

final class MockDanmaku: DanmakuConnector, @unchecked Sendable {
    private let recorder: CallRecorder
    let platform: DanmakuPlatform = .bilibili

    let events: AsyncStream<DanmakuEvent>
    let eventsCont: AsyncStream<DanmakuEvent>.Continuation
    let states: AsyncStream<ConnectorState>
    let statesCont: AsyncStream<ConnectorState>.Continuation

    init(recorder: CallRecorder) {
        self.recorder = recorder
        (events, eventsCont) = AsyncStream.makeStream(of: DanmakuEvent.self)
        (states, statesCont) = AsyncStream.makeStream(of: ConnectorState.self)
    }

    func start() async { recorder.record("danmaku.start") }
    func stop() async { recorder.record("danmaku.stop") }
}

// MARK: - MockComposer（输出可辨识的文本节点，canonicalJSON 随输入变化）

struct MockComposer: GlassScreenComposing {
    func danmakuScreen(events: [DanmakuEvent], mode: DanmakuFilterMode,
                       status: LiveStatusSummary) -> GlassNode {
        .text("danmaku|\(mode.rawValue)|\(events.count)", style: .body, color: .primary)
    }

    func highValueCard(event: DanmakuEvent, remaining: TimeInterval,
                       underlying: [DanmakuEvent], mode: DanmakuFilterMode,
                       status: LiveStatusSummary) -> GlassNode {
        .text("card|\(event.id)|\(mode.rawValue)", style: .heading, color: .primary)
    }

    func statusScreen(status: LiveStatusSummary) -> GlassNode {
        .text("status", style: .body, color: .secondary)
    }

    func alertScreen(fault: GlassesFault, degradedPreset: CameraPreset?) -> GlassNode {
        .text("alert|\(degradedPreset?.quality.rawValue ?? "none")", style: .heading, color: .primary)
    }
}

// MARK: - 组装

struct CoordinatorHarness {
    let recorder: CallRecorder
    let glasses: MockGlasses
    let pipeline: MockPipeline
    let audio: MockAudio
    let danmaku: MockDanmaku
    let clock: VirtualClock
    let coordinator: SessionCoordinator

    init() {
        let recorder = CallRecorder()
        self.recorder = recorder
        glasses = MockGlasses(recorder: recorder)
        pipeline = MockPipeline(recorder: recorder)
        audio = MockAudio(recorder: recorder)
        danmaku = MockDanmaku(recorder: recorder)
        clock = VirtualClock()
        coordinator = SessionCoordinator(glasses: glasses,
                                         pipeline: pipeline,
                                         audio: audio,
                                         danmaku: danmaku,
                                         composer: MockComposer(),
                                         clock: clock)
    }

    static func defaultConfiguration(
        preset: CameraPreset = .default,
        audioSource: AudioSource = .iphoneMic,
        danmakuEnabled: Bool = true
    ) -> LiveSessionConfiguration {
        LiveSessionConfiguration(
            target: RTMPTarget(preset: .bilibiliLiveHime, name: "B 站 · 直播姬中转",
                               serverURL: "rtmp://192.168.31.10/live", streamKeyRef: "test-key-ref"),
            streamKey: "sk-test",
            cameraPreset: preset,
            audioSource: audioSource,
            danmakuEnabled: danmakuEnabled)
    }

    func chatEvent(id: String, text: String = "弹幕内容", question: Bool = false) -> DanmakuEvent {
        DanmakuEvent(id: id, platform: .bilibili, kind: .chat, user: "观众\(id)",
                     text: text, timestamp: clock.now, isQuestion: question)
    }

    func superChatEvent(id: String) -> DanmakuEvent {
        DanmakuEvent(id: id, platform: .bilibili, kind: .superChat, user: "金主\(id)",
                     text: "SC 内容", value: 30, timestamp: clock.now)
    }
}

// MARK: - 异步断言助手

enum TestWaitError: Error { case timeout }

/// 轮询快照流直到谓词命中（订阅即回放当前快照，适合断言"最终状态"）
func waitForSnapshot(_ coordinator: SessionCoordinator,
                     timeout: TimeInterval = 2,
                     where predicate: @escaping @Sendable (LiveSessionSnapshot) -> Bool) async throws -> LiveSessionSnapshot {
    let stream = await coordinator.snapshotStream()
    return try await withThrowingTaskGroup(of: LiveSessionSnapshot.self) { group in
        group.addTask {
            for await snapshot in stream where predicate(snapshot) {
                return snapshot
            }
            throw TestWaitError.timeout
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            throw TestWaitError.timeout
        }
        guard let first = try await group.next() else { throw TestWaitError.timeout }
        group.cancelAll()
        return first
    }
}

/// 轮询任意条件（用于等 mock 记录/发送计数达到期望）
func waitUntil(timeout: TimeInterval = 2,
               _ condition: @escaping @Sendable () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    if condition() { return }
    throw TestWaitError.timeout
}
