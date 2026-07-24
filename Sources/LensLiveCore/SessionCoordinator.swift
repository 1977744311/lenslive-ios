// SessionCoordinator —— 总状态机（架构 §3.1 开播时序 / §4 状态推导 / §6 降级矩阵）。
// 编排六路协议注入，核心语义：
// 1. 上行推流与下行弹幕独立降级：danmaku/display/audio 掉线只进 degraded，绝不停推流；
//    camera/rtmp 失败降级但保会话；glasses 断连交给 GlassesKit 重连，这里消费恢复通知。
// 2. captouch：tap 在驻留卡期间=已读，否则循环三档；backOnRoot 只发确认请求，不直接停。
// 3. 热/电故障 → notice + 可选自动降档（重新 attachCamera 换低一档 preset）。
// 4. 系统中断（来电）→ interrupted → 恢复后 resuming → 按就绪位图回 live/degraded。
import Foundation
import AudioHub
import DanmakuCore
import GlassRenderer
import GlassesKit
import StreamEngine

public actor SessionCoordinator {

    public enum StartError: Error, Equatable {
        case alreadyActive
        case glassesUnavailable(reason: String)
    }

    // MARK: - 注入

    private let glasses: any GlassesSessionProviding
    private let pipeline: any StreamPipelining     // 集成时注入 StreamEngine 的 StreamSessionController
    private let audio: any AudioRouting
    private let danmaku: any DanmakuConnector
    private let composer: any GlassScreenComposing // 集成时注入 GlassRenderer 的 GlassScreenComposer
    private let clock: any Clock_

    public init(glasses: any GlassesSessionProviding,
                pipeline: any StreamPipelining,
                audio: any AudioRouting,
                danmaku: any DanmakuConnector,
                composer: any GlassScreenComposing,
                clock: any Clock_ = SystemClock()) {
        self.glasses = glasses
        self.pipeline = pipeline
        self.audio = audio
        self.danmaku = danmaku
        self.composer = composer
        self.clock = clock
    }

    // MARK: - 状态

    private var config: LiveSessionConfiguration?
    private var phase: LiveSessionPhase = .idle
    private var readiness = ReadinessBitmap()
    private var targetSubsystems: Set<Subsystem> = []

    private var startedAt: Date?
    private var stats: StreamStats?
    private var thermal: ThermalLevel = .normal
    private var batteryCritical = false
    private var danmakuBuffer: [DanmakuEvent] = []
    private var filterMode: DanmakuFilterMode = .all
    private var notices: [DatedNotice] = []
    private var noticeSeq = 0
    private var cameraPreset: CameraPreset = .default
    private var audioSource: AudioSource = .iphoneMic
    private var viewers: Int?
    private var awaitingEndConfirmation = false

    /// 眼镜中断原因（区分"来电恢复"与"蓝牙重连恢复"两种 .started 语义）
    private enum GlassesOutage { case none, bluetooth, systemPause }
    private var glassesOutage: GlassesOutage = .none
    private var danmakuDown = false
    /// 已针对该热等级执行过告警/降档（避免同级重复触发；降温后复位）
    private var lastThermalActioned: ThermalLevel = .normal

    // 眼镜屏发送
    private var lastSentPayload: DisplayPayload?
    private var displayRefreshPending = false
    private var dwellDeadline: Date?
    private var dwellGeneration = 0

    // 任务
    private var monitors: [Task<Void, Never>] = []
    private var tickerTask: Task<Void, Never>?
    private var throttleTask: Task<Void, Never>?
    private var dwellTask: Task<Void, Never>?

    // 快照订阅
    private var subscribers: [UUID: AsyncStream<LiveSessionSnapshot>.Continuation] = [:]

    // MARK: - 快照输出

    /// 多订阅者、订阅即回放当前快照。
    public func snapshotStream() -> AsyncStream<LiveSessionSnapshot> {
        AsyncStream { continuation in
            let id = UUID()
            subscribers[id] = continuation
            continuation.yield(makeSnapshot())
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(id) }
            }
        }
    }

    public func currentSnapshot() -> LiveSessionSnapshot { makeSnapshot() }

    private func removeSubscriber(_ id: UUID) { subscribers[id] = nil }

    private func makeSnapshot() -> LiveSessionSnapshot {
        LiveSessionSnapshot(
            phase: phase,
            readiness: readiness,
            startedAt: startedAt,
            elapsed: startedAt.map { clock.now.timeIntervalSince($0) } ?? 0,
            stats: stats,
            glassesHealth: GlassesHealth(bluetoothLinkUp: readiness.ready.contains(.glasses),
                                         cameraStreaming: readiness.ready.contains(.camera),
                                         displayReady: readiness.ready.contains(.display),
                                         thermal: thermal,
                                         batteryCritical: batteryCritical),
            danmakuBuffer: danmakuBuffer,
            filterMode: filterMode,
            notices: notices,
            cameraPreset: cameraPreset,
            audioSource: audioSource,
            viewers: viewers,
            awaitingEndConfirmation: awaitingEndConfirmation)
    }

    private func publish() {
        let snap = makeSnapshot()
        for continuation in subscribers.values { continuation.yield(snap) }
    }

    // MARK: - 开播（架构 §3.1）

    /// 时序：glasses.start → attachCamera → audio.activate（HFP 须在推流前稳定）
    ///      → 推流 start → attachDisplay + 首屏 → danmaku start。
    /// 仅 glasses.start 失败抛错终止；camera/rtmp/display 失败降级但保会话。
    public func startLive(configuration: LiveSessionConfiguration) async throws {
        guard phase == .idle else { throw StartError.alreadyActive }

        config = configuration
        resetSessionState(configuration: configuration)
        phase = .preparing
        publish()

        targetSubsystems = configuration.danmakuEnabled
            ? Set(Subsystem.allCases)
            : Set(Subsystem.allCases).subtracting([.danmaku])

        // 1. 眼镜会话 —— 地基，失败即整体失败
        do {
            try await glasses.start()
        } catch {
            phase = .idle
            config = nil
            publish()
            throw StartError.glassesUnavailable(reason: String(describing: error))
        }
        readiness.ready.insert(.glasses)

        // 2. 相机流（失败降级保会话）
        do {
            try await glasses.attachCamera(preset: configuration.cameraPreset)
            readiness.ready.insert(.camera)
        } catch {
            readiness.ready.remove(.camera)
        }

        // 3. 音源 —— HFP 需在推流启动前路由稳定；失败回退由 AudioHub 保证，
        //    这里只接收最终生效源，fallback 通知经 audio.states 消费。
        audioSource = await audio.activate(configuration.audioSource)
        readiness.ready.insert(.audio)

        // 4. RTMP 推流（失败降级保会话，弹幕照常拉起 —— 推流挂了弹幕还在）
        do {
            try await pipeline.start(target: configuration.target, streamKey: configuration.streamKey)
            readiness.ready.insert(.rtmp)
        } catch {
            appendNotice(.rtmpGaveUp)
        }

        // 5. 眼镜屏 + 首屏
        do {
            try await glasses.attachDisplay()
            readiness.ready.insert(.display)
            await sendDanmakuScreenNow()
        } catch {
            readiness.ready.remove(.display)
        }

        // 6. 弹幕连接（乐观置位，断连由 connector states 驱动降级）
        if configuration.danmakuEnabled {
            await danmaku.start()
            readiness.ready.insert(.danmaku)
        }

        startedAt = clock.now
        phase = readiness.phase(whenTargetIs: targetSubsystems)
        publish()

        startMonitors(configuration: configuration)
        startTicker()
    }

    // MARK: - 停止（严格逆序收尾）

    public func stopLive() async {
        switch phase {
        case .idle, .ending: return
        default: break
        }
        phase = .ending
        awaitingEndConfirmation = false
        publish()

        cancelAllTasks()

        // 逆序：danmaku → display（清屏+卸载）→ 推流 → 音源 → 相机 → 会话
        if config?.danmakuEnabled == true { await danmaku.stop() }
        try? await glasses.clearDisplay()
        await glasses.detachDisplay()
        await pipeline.stop()
        await audio.deactivate()
        await glasses.detachCamera()
        await glasses.stop()

        resetSessionState(configuration: nil)
        config = nil
        phase = .idle
        publish()
    }

    private func resetSessionState(configuration: LiveSessionConfiguration?) {
        readiness = ReadinessBitmap()
        startedAt = nil
        stats = nil
        danmakuBuffer = []
        notices = []
        noticeSeq = 0
        filterMode = .all
        batteryCritical = false
        glassesOutage = .none
        danmakuDown = false
        lastThermalActioned = .normal
        lastSentPayload = nil
        displayRefreshPending = false
        dwellDeadline = nil
        dwellGeneration = 0
        awaitingEndConfirmation = false
        cameraPreset = configuration?.cameraPreset ?? .default
        audioSource = configuration?.audioSource ?? .iphoneMic
    }

    // MARK: - UI 动作

    /// captouch backOnRoot 的取消侧（用户在确认弹窗点"继续直播"）
    public func cancelEndRequest() {
        awaitingEndConfirmation = false
        publish()
    }

    /// 确认结束（确认弹窗的"结束直播"）
    public func confirmEndAndStop() async {
        awaitingEndConfirmation = false
        await stopLive()
    }

    /// UI 侧直接设档（与 captouch 循环共用同一档位机）
    public func setFilterMode(_ mode: DanmakuFilterMode) async {
        guard filterMode != mode else { return }
        filterMode = mode
        clearDwell()
        publish()
        await sendDanmakuScreenNow()
    }

    /// F4：直播中切换音源（回退语义仍由 AudioHub 保证）
    public func setAudioSource(_ source: AudioSource) async {
        audioSource = await audio.activate(source)
        readiness.ready.insert(.audio)
        recomputePhaseFromReadiness()
    }

    /// 在线人数回填（B 站开放平台/未来数据源/Mock 注入；nil = 无数据）
    public func updateViewers(_ count: Int?) {
        viewers = count
        publish()
    }

    // MARK: - 监听

    private func startMonitors(configuration: LiveSessionConfiguration) {
        monitors.append(Task { [weak self, stream = glasses.sessionStates] in
            for await state in stream {
                guard let self else { return }
                await self.handleSessionState(state)
            }
        })
        monitors.append(Task { [weak self, stream = glasses.displayStates] in
            for await state in stream {
                guard let self else { return }
                await self.handleDisplayState(state)
            }
        })
        monitors.append(Task { [weak self, stream = glasses.cameraStates] in
            for await state in stream {
                guard let self else { return }
                await self.handleCameraState(state)
            }
        })
        monitors.append(Task { [weak self, stream = glasses.thermal] in
            for await level in stream {
                guard let self else { return }
                await self.handleThermal(level)
            }
        })
        monitors.append(Task { [weak self, stream = glasses.faults] in
            for await fault in stream {
                guard let self else { return }
                await self.handleFault(fault)
            }
        })
        monitors.append(Task { [weak self, stream = glasses.captouch] in
            for await gesture in stream {
                guard let self else { return }
                await self.handleCaptouch(gesture)
            }
        })
        // 相机帧直通推流管线（性能敏感路径不过 actor，直接转发）
        monitors.append(Task { [pipeline, stream = glasses.cameraFrames] in
            for await frame in stream {
                if Task.isCancelled { return }
                await pipeline.appendVideoPayload(frame.payload ?? frame.sequence,
                                                  timestampSeconds: frame.timestamp.timeIntervalSince1970)
            }
        })
        monitors.append(Task { [weak self, stream = pipeline.states] in
            for await state in stream {
                guard let self else { return }
                await self.handlePipelineState(state)
            }
        })
        monitors.append(Task { [weak self, stream = pipeline.stats] in
            for await stats in stream {
                guard let self else { return }
                await self.handleStats(stats)
            }
        })
        monitors.append(Task { [weak self, stream = audio.states] in
            for await state in stream {
                guard let self else { return }
                await self.handleAudioState(state)
            }
        })
        if configuration.danmakuEnabled {
            monitors.append(Task { [weak self, stream = danmaku.states] in
                for await state in stream {
                    guard let self else { return }
                    await self.handleConnectorState(state)
                }
            })
            monitors.append(Task { [weak self, stream = danmaku.events] in
                for await event in stream {
                    guard let self else { return }
                    await self.handleDanmakuEvent(event)
                }
            })
        }
    }

    /// 1Hz 走秒：仅刷新快照（elapsed），不做业务
    private func startTicker() {
        tickerTask = Task { [weak self, clock] in
            while !Task.isCancelled {
                do { try await clock.sleep(seconds: 1) } catch { return }
                guard let self else { return }
                let active = await self.isSessionActive()
                guard active else { return }
                await self.publishTick()
            }
        }
    }

    private func isSessionActive() -> Bool {
        switch phase {
        case .idle, .ending: return false
        default: return true
        }
    }

    private func publishTick() { publish() }

    private func cancelAllTasks() {
        monitors.forEach { $0.cancel() }
        monitors = []
        tickerTask?.cancel(); tickerTask = nil
        throttleTask?.cancel(); throttleTask = nil
        dwellTask?.cancel(); dwellTask = nil
        displayRefreshPending = false
    }

    // MARK: - 眼镜事件

    private func handleSessionState(_ state: GlassesSessionState) {
        guard isSessionActive() else { return }
        switch state {
        case .paused:
            enterInterrupted()
        case .started:
            switch (phase, glassesOutage) {
            case (.interrupted, _):
                // 来电结束 → resuming → 按位图回 live/degraded（架构 §4）
                phase = .resuming
                publish()
                appendNotice(.resumed)
                readiness.ready.insert(.glasses)
                glassesOutage = .none
                Task { [weak self] in await self?.resendLastPayload() }
                phase = readiness.phase(whenTargetIs: targetSubsystems)
                publish()
            case (_, .bluetooth):
                // GlassesKit 内部重连成功（恢复通知）→ 重发最后一屏
                appendNotice(.bluetoothRecovered)
                glassesOutage = .none
                readiness.ready.insert(.glasses)
                Task { [weak self] in await self?.resendLastPayload() }
                recomputePhaseFromReadiness()
            default:
                readiness.ready.insert(.glasses)
                recomputePhaseFromReadiness()
            }
        case .stopped:
            // 非主动收尾的 stopped = 链路中断，等 GlassesKit 重连（不停推流）
            readiness.ready.remove(.glasses)
            recomputePhaseFromReadiness()
        case .idle, .starting, .stopping:
            break
        }
    }

    private func handleDisplayState(_ state: DisplayState) {
        guard isSessionActive() else { return }
        switch state {
        case .started:
            readiness.ready.insert(.display)
            recomputePhaseFromReadiness()
        case .stopped:
            readiness.ready.remove(.display)
            recomputePhaseFromReadiness()
        case .starting, .stopping:
            break
        }
    }

    private func handleCameraState(_ state: CameraStreamState) {
        guard isSessionActive() else { return }
        switch state {
        case .streaming:
            readiness.ready.insert(.camera)
            recomputePhaseFromReadiness()
        case .stopped:
            readiness.ready.remove(.camera)
            recomputePhaseFromReadiness()
        case .waitingForDevice, .starting, .paused, .stopping:
            break
        }
    }

    private func handleFault(_ fault: GlassesFault) async {
        guard isSessionActive() else { return }
        switch fault {
        case .bluetoothLost:
            appendNotice(.bluetoothLost)
            glassesOutage = .bluetooth
            readiness.ready.remove(.glasses)
            recomputePhaseFromReadiness()
        case .thermal(let level):
            await handleThermal(level)
        case .batteryCritical:
            batteryCritical = true
            appendNotice(.batteryCritical)
            await sendAlertScreen(fault: .batteryCritical, degradedPreset: nil)
            publish()
        case .systemInterrupted:
            enterInterrupted()
        case .capabilityDenied, .datAppUpdateRequired:
            // 契约暂无对应 notice；先以位图降级暴露，避免静默失败
            readiness.ready.remove(.glasses)
            recomputePhaseFromReadiness()
        }
    }

    private func enterInterrupted() {
        guard phase != .interrupted, isSessionActive() else { return }
        phase = .interrupted
        glassesOutage = .systemPause
        appendNotice(.interruptedBySystem)
        publish()
    }

    // MARK: - 热管理（G4：告警 + 可选自动降档 720→504→360）

    private func handleThermal(_ level: ThermalLevel) async {
        guard isSessionActive() else { return }
        thermal = level
        defer { publish() }

        if level < .hot {
            lastThermalActioned = level   // 降温复位，允许下次升温再触发
            return
        }
        guard level > lastThermalActioned else { return }
        lastThermalActioned = level

        var degradedTo: CameraPreset?
        if config?.autoThermalDowngrade == true,
           let lower = cameraPreset.quality.lowerQuality {
            degradedTo = CameraPreset(quality: lower, frameRate: cameraPreset.frameRate)
        }
        appendNotice(.thermalWarning(level, degradedTo: degradedTo))

        if let preset = degradedTo {
            do {
                try await glasses.attachCamera(preset: preset)
                cameraPreset = preset
            } catch {
                readiness.ready.remove(.camera)
                recomputePhaseFromReadiness()
            }
        }
        await sendAlertScreen(fault: .thermal(level), degradedPreset: degradedTo)
    }

    // MARK: - captouch 路由

    private func handleCaptouch(_ gesture: CaptouchGesture) async {
        guard isSessionActive() else { return }
        switch gesture {
        case .tap:
            if dwellDeadline != nil {
                // 驻留卡展示中 → tap = 已读，回落普通屏，不改档位
                clearDwell()
                await sendDanmakuScreenNow()
            } else {
                filterMode = filterMode.next
                publish()
                await sendDanmakuScreenNow()
            }
        case .backOnRoot:
            // 会话结束语义 → 只发确认请求，等手机端二次确认，绝不直接停
            awaitingEndConfirmation = true
            publish()
        }
    }

    // MARK: - 推流事件

    private func handlePipelineState(_ state: StreamPipelineState) {
        guard isSessionActive() else { return }
        switch state {
        case .streaming:
            readiness.ready.insert(.rtmp)
            recomputePhaseFromReadiness()
        case .reconnecting(let attempt):
            readiness.ready.remove(.rtmp)
            appendNotice(.rtmpReconnecting(attempt: attempt))
            recomputePhaseFromReadiness()
        case .failed:
            readiness.ready.remove(.rtmp)
            appendNotice(.rtmpGaveUp)
            recomputePhaseFromReadiness()
        case .stopped:
            readiness.ready.remove(.rtmp)
            recomputePhaseFromReadiness()
        case .idle, .connecting:
            break
        }
    }

    private func handleStats(_ newStats: StreamStats) {
        guard isSessionActive() else { return }
        stats = newStats
        publish()
    }

    // MARK: - 音源事件

    private func handleAudioState(_ state: AudioRouteState) {
        guard isSessionActive() else { return }
        switch state {
        case .active(let source):
            audioSource = source
            readiness.ready.insert(.audio)
            recomputePhaseFromReadiness()
        case .fallback(let from, let to, _):
            appendNotice(.audioFallback(from: from, to: to))
            audioSource = to
            readiness.ready.insert(.audio)
            recomputePhaseFromReadiness()
        case .failed:
            readiness.ready.remove(.audio)
            recomputePhaseFromReadiness()
        case .inactive, .configuring, .settling:
            break
        }
    }

    // MARK: - 弹幕事件

    private func handleConnectorState(_ state: ConnectorState) {
        guard isSessionActive() else { return }
        switch state {
        case .connected:
            if danmakuDown {
                appendNotice(.danmakuRecovered)
                danmakuDown = false
            }
            readiness.ready.insert(.danmaku)
            recomputePhaseFromReadiness()
        case .reconnecting, .failed:
            markDanmakuDisconnected()
        case .stopped:
            // 会话存续期的意外 stopped 同断连处理（主动收尾时监听已撤）
            markDanmakuDisconnected()
        case .idle, .connecting:
            break
        }
    }

    private func markDanmakuDisconnected() {
        if !danmakuDown {
            appendNotice(.danmakuDisconnected)
            danmakuDown = true
        }
        readiness.ready.remove(.danmaku)
        recomputePhaseFromReadiness()
    }

    private func handleDanmakuEvent(_ event: DanmakuEvent) async {
        guard isSessionActive() else { return }
        danmakuBuffer.append(event)
        let limit = config?.danmakuBufferLimit ?? 120
        if danmakuBuffer.count > limit {
            danmakuBuffer.removeFirst(danmakuBuffer.count - limit)
        }
        publish()

        // 眼镜上屏：暂停档/系统中断期不发送
        guard phase != .interrupted, filterMode != .paused else { return }
        if event.isHighValue {
            await presentHighValueCard(event)
        } else if filterMode == .all, displayableOnGlass(event) {
            scheduleThrottledDisplayRefresh()
        }
    }

    private func displayableOnGlass(_ event: DanmakuEvent) -> Bool {
        if event.kind == .system { return false }
        if event.kind == .enter, config?.blockEnterMessages == true { return false }
        return true
    }

    // MARK: - 眼镜屏发送（节流 / 驻留 / 幂等去重）

    private func glassEvents() -> [DanmakuEvent] {
        let lineCount = config?.displayLineCount ?? 6
        let visible: [DanmakuEvent]
        switch filterMode {
        case .highValueOnly:
            visible = danmakuBuffer.filter(\.isHighValue)
        default:
            visible = danmakuBuffer.filter { displayableOnGlass($0) }
        }
        return Array(visible.suffix(lineCount))
    }

    private func sendDanmakuScreenNow() async {
        guard isSessionActive() else { return }
        let node = composer.danmakuScreen(events: glassEvents(),
                                          mode: filterMode,
                                          status: makeSnapshot().statusSummary)
        await sendNode(node)
    }

    private func presentHighValueCard(_ event: DanmakuEvent) async {
        let dwell = config?.highValueDwell ?? 8
        dwellGeneration += 1
        let generation = dwellGeneration
        dwellDeadline = clock.now.addingTimeInterval(dwell)

        let node = composer.highValueCard(event: event,
                                          remaining: dwell,
                                          underlying: glassEvents(),
                                          mode: filterMode,
                                          status: makeSnapshot().statusSummary)
        await sendNode(node)

        dwellTask?.cancel()
        dwellTask = Task { [weak self, clock] in
            do { try await clock.sleep(seconds: dwell) } catch { return }
            await self?.dwellExpired(generation: generation)
        }
    }

    private func dwellExpired(generation: Int) async {
        guard generation == dwellGeneration else { return }
        dwellDeadline = nil
        await sendDanmakuScreenNow()
    }

    private func clearDwell() {
        dwellGeneration += 1
        dwellDeadline = nil
        dwellTask?.cancel()
        dwellTask = nil
    }

    private func scheduleThrottledDisplayRefresh() {
        guard !displayRefreshPending else { return }
        displayRefreshPending = true
        let throttle = config?.displayThrottle ?? 1
        throttleTask = Task { [weak self, clock] in
            do { try await clock.sleep(seconds: throttle) } catch { return }
            await self?.throttleFired()
        }
    }

    private func throttleFired() async {
        displayRefreshPending = false
        guard isSessionActive(), phase != .interrupted, filterMode != .paused else { return }
        // 高价值卡驻留期间普通刷新不覆盖卡片；驻留到期任务会补一次全量刷新
        if let deadline = dwellDeadline, clock.now < deadline { return }
        await sendDanmakuScreenNow()
    }

    private func sendNode(_ node: GlassNode) async {
        guard let json = try? GlassNodeEncoder.canonicalJSON(node) else { return }
        let payload = DisplayPayload(canonicalJSON: json)
        if payload == lastSentPayload { return }   // canonicalJSON 幂等去重
        do {
            try await glasses.sendDisplayPayload(payload)
            lastSentPayload = payload
        } catch {
            readiness.ready.remove(.display)
            recomputePhaseFromReadiness()
        }
    }

    /// 蓝牙/中断恢复后重发最后一屏（降级矩阵"恢复后重挂能力 + 重发最后一屏"）
    private func resendLastPayload() async {
        guard let payload = lastSentPayload else { return }
        try? await glasses.sendDisplayPayload(payload)
    }

    private func sendAlertScreen(fault: GlassesFault, degradedPreset: CameraPreset?) async {
        let node = composer.alertScreen(fault: fault, degradedPreset: degradedPreset)
        await sendNode(node)
    }

    // MARK: - phase / notice

    /// live/degraded 之间由就绪位图推导；其余生命周期态不被位图覆盖
    private func recomputePhaseFromReadiness() {
        switch phase {
        case .live, .degraded:
            phase = readiness.phase(whenTargetIs: targetSubsystems)
        default:
            break
        }
        publish()
    }

    private func appendNotice(_ notice: CoordinatorNotice) {
        noticeSeq += 1
        notices.append(DatedNotice(id: noticeSeq, notice: notice, postedAt: clock.now))
        let limit = config?.noticeLimit ?? 20
        if notices.count > limit {
            notices.removeFirst(notices.count - limit)
        }
        publish()
    }
}

// MARK: - 画质降档梯子（720→504→360）

private extension CameraPreset.Quality {
    var lowerQuality: CameraPreset.Quality? {
        switch self {
        case .high: return .medium
        case .medium: return .low
        case .low: return nil
        }
    }
}
