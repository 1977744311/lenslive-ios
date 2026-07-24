// 断连恢复编排（纯逻辑 + 时钟注入）。
// 蓝牙丢失 → 退避重连（1s 倍增封顶 30s，不设次数上限）→ 恢复后按序重挂：
// camera → display → 重发最后一次 DisplayPayload。
// 一次"尝试"= start + 全部重挂：任一步失败都进入下一轮退避，
// 保证不会出现"会话已连但能力挂了一半"的中间态被当作成功。
import Foundation

public enum ReconnectEvent: Sendable, Equatable {
    case attemptScheduled(attempt: Int, delay: TimeInterval)
    case attemptStarted(attempt: Int)
    case attemptFailed(attempt: Int)
    case sessionRestarted(attempt: Int)
    case cameraReattached
    case displayReattached
    case lastPayloadResent
    case recovered(attempts: Int)
}

public actor GlassesReconnectManager {

    public struct Config: Sendable {
        public var initialDelay: TimeInterval
        public var maxDelay: TimeInterval
        public var multiplier: Double

        public init(initialDelay: TimeInterval = 1, maxDelay: TimeInterval = 30, multiplier: Double = 2) {
            self.initialDelay = initialDelay
            self.maxDelay = maxDelay
            self.multiplier = multiplier
        }
    }

    private let session: any GlassesSessionProviding
    private let clock: any GlassesClocking
    private let config: Config
    private let bus = StreamBroadcaster<ReconnectEvent>()

    private var lastPayload: DisplayPayload?
    private var cameraPreset: CameraPreset = .default
    private var monitorTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?

    public init(session: any GlassesSessionProviding,
                clock: any GlassesClocking = GlassesSystemClock(),
                config: Config = Config()) {
        self.session = session
        self.clock = clock
        self.config = config
    }

    /// attempt / 重挂进度事件流（多订阅）
    public nonisolated var events: AsyncStream<ReconnectEvent> { bus.subscribe() }

    // MARK: - 上层喂入的恢复上下文

    /// 每次成功送屏后记录，恢复时重发（上层在发送路径旁路调用）
    public func recordLastPayload(_ payload: DisplayPayload) { lastPayload = payload }

    /// 当前生效的相机档位（热降档后应更新），恢复时按此重挂
    public func recordCameraPreset(_ preset: CameraPreset) { cameraPreset = preset }

    // MARK: - 编排

    /// 订阅 provider 故障流，.bluetoothLost 自动触发恢复
    public func startMonitoring() {
        guard monitorTask == nil else { return }
        let faults = session.faults
        monitorTask = Task { [weak self] in
            for await fault in faults {
                guard !Task.isCancelled else { return }
                if fault == .bluetoothLost {
                    await self?.beginRecovery()
                }
            }
        }
    }

    /// 手动触发恢复（幂等：恢复进行中重复调用被忽略）
    public func beginRecovery() {
        guard recoveryTask == nil else { return }
        recoveryTask = Task { [weak self] in
            await self?.runRecoveryLoop()
            await self?.clearRecoveryTask()
        }
    }

    public func stop() {
        monitorTask?.cancel()
        monitorTask = nil
        recoveryTask?.cancel()
        recoveryTask = nil
    }

    // MARK: - 内部

    private func clearRecoveryTask() { recoveryTask = nil }

    private func runRecoveryLoop() async {
        var attempt = 0
        var delay = config.initialDelay
        while !Task.isCancelled {
            attempt += 1
            bus.send(.attemptScheduled(attempt: attempt, delay: delay))
            do { try await clock.sleep(seconds: delay) } catch { return }
            bus.send(.attemptStarted(attempt: attempt))
            do {
                try await session.start()
                bus.send(.sessionRestarted(attempt: attempt))
                try await session.attachCamera(preset: cameraPreset)
                bus.send(.cameraReattached)
                try await session.attachDisplay()
                bus.send(.displayReattached)
                if let payload = lastPayload {
                    try await session.sendDisplayPayload(payload)
                    bus.send(.lastPayloadResent)
                }
                bus.send(.recovered(attempts: attempt))
                return
            } catch {
                bus.send(.attemptFailed(attempt: attempt))
                delay = min(delay * config.multiplier, config.maxDelay)
            }
        }
    }
}
