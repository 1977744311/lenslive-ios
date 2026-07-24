// DATGlassesSessionAdapter —— 真实 Meta Wearables DAT SDK (0.8.0) → GlassesSessionProviding 适配。
// 本文件只随 App target（xcodegen 工程）编译，不参与 swift build；整文件由 canImport 守护。
// ⚠️ 真机验证项见研究文档 §7（steven-ai-lab 任务目录 research-live-danmaku.md 第 7 节）：
//    同会话 addStream+addDisplay 共存、休眠中 send 行为、1Hz send 稳定性、热/续航曲线等。
//
// ── 0.8.0 真实 API 与契约的能力差距（对照各 xcframework 的 arm64-apple-ios.swiftinterface）──
//  · 设备发现没有独立"选择"调用：AutoDeviceSelector 直接注入 createSession(deviceSelector:)，
//    会话自行等待设备；活跃设备经 selector.activeDeviceStream() 跟随，热观测随之切换。
//  · session/stream/display 的 start·stop 均为同步，状态经 stateStream()/statePublisher 回流；
//    仅 display.send/clearDisplay 为 async throws。相机/显示能力对象为 Stream/Display，
//    事件走 Announcer.listen（token 取消），此处统一桥成 AsyncStream 消费。
//  · 相机分辨率是预设枚举（StreamingResolution high/medium/low），与契约 CameraPreset.pixelSize
//    三档规格一致，按 quality 直接映射；帧载荷 VideoFrame.sampleBuffer 即 raw CMSampleBuffer。
//  · 组件树：FlexBox/Text/Button/Icon/Image 皆 ViewComponent，但 display.send 只收
//    DisplayableView（FlexBox/VideoPlayer）——非 FlexBox 根节点需包一层 FlexBox。
//    契约 gap→spacing、padding(Int)→EdgeInsets(all:)；FlexBox.onClick 只读，可点击用 .onTap。
//  · captouch：SDK 无全局手势流，组件 onTap 归一为 .tap + displayActions(actionID) 两条流；
//    back 手势无独立回调：L0 上 back 直接结束 display 会话 → 以"display 意外 stopped 且
//    session 仍 started"启发式合成 .backOnRoot（需真机核验）。
//  · ThermalLevel 为 8 档（unknown…shutdown），契约 4 档，做区间归并。
//  · 0.8.0 图标目录无 gift/warning，用 shoppingBag/exclamationTriangle 近似。
#if canImport(MWDATCore) && canImport(MWDATDisplay) && canImport(MWDATCamera)
import Foundation
import CoreMedia
import MWDATCore
import MWDATCamera
import MWDATDisplay
import GlassesKit
import GlassRenderer

/// 真实相机帧载荷：包一层以通过 Sendable 边界（CMSampleBuffer 本身非 Sendable，
/// 消费方（StreamEngine）在帧管线内同步取用，不跨任务存留）
public struct DATCameraFramePayload: @unchecked Sendable {
    public let sampleBuffer: CMSampleBuffer
    public init(sampleBuffer: CMSampleBuffer) { self.sampleBuffer = sampleBuffer }
}

public actor DATGlassesSessionAdapter: GlassesSessionProviding {

    // MARK: - 扇出总线（与 Mock 同一套基础设施）

    private let sessionBus = StreamBroadcaster<GlassesSessionState>(replaysLatest: true)
    private let displayBus = StreamBroadcaster<GlassesKit.DisplayState>(replaysLatest: true)
    private let cameraBus = StreamBroadcaster<CameraStreamState>(replaysLatest: true)
    private let thermalBus = StreamBroadcaster<GlassesKit.ThermalLevel>(replaysLatest: true)
    private let faultBus = StreamBroadcaster<GlassesFault>()
    private let captouchBus = StreamBroadcaster<CaptouchGesture>()
    private let frameBus = StreamBroadcaster<CameraFramePacket>()
    /// 契约缺口补充：captouch 流不带 tap 区域信息，组件级 onClick 的 actionID 走本流
    private let actionBus = StreamBroadcaster<String>()

    // MARK: - SDK 句柄

    private var deviceSelector: AutoDeviceSelector?
    private var session: DeviceSession?
    private var cameraStream: MWDATCamera.Stream?
    private var display: MWDATDisplay.Display?

    private var observationTasks: [Task<Void, Never>] = []
    private var thermalTask: Task<Void, Never>?
    private var displayTask: Task<Void, Never>?
    private var cameraTasks: [Task<Void, Never>] = []
    private var frameSequence: UInt64 = 0

    private var lastKnownSessionState: GlassesSessionState = .idle
    private var lastKnownDisplayState: GlassesKit.DisplayState = .stopped
    private var displayDetachRequested = false

    public init() {}

    // MARK: - GlassesSessionProviding：流

    public nonisolated var sessionStates: AsyncStream<GlassesSessionState> { sessionBus.subscribe() }
    public nonisolated var displayStates: AsyncStream<GlassesKit.DisplayState> { displayBus.subscribe() }
    public nonisolated var cameraStates: AsyncStream<CameraStreamState> { cameraBus.subscribe() }
    public nonisolated var thermal: AsyncStream<GlassesKit.ThermalLevel> { thermalBus.subscribe() }
    public nonisolated var faults: AsyncStream<GlassesFault> { faultBus.subscribe() }
    public nonisolated var captouch: AsyncStream<CaptouchGesture> { captouchBus.subscribe() }
    public nonisolated var cameraFrames: AsyncStream<CameraFramePacket> { frameBus.subscribe() }

    /// 组件 onClick 的 actionID 流（契约外补充；SessionCoordinator 据此驱动
    /// DanmakuFilterMachine.handle(.tap(actionID:)) 等）
    public nonisolated var displayActions: AsyncStream<String> { actionBus.subscribe() }

    // MARK: - GlassesSessionProviding：生命周期

    public func start() async throws {
        guard session == nil else { return }
        // configure 幂等化：重复初始化抛 alreadyConfigured，视为已就绪
        do {
            try Wearables.configure()
        } catch WearablesError.alreadyConfigured {
        } catch {
            throw GlassesSessionError.underlying(String(describing: error))
        }
        // 仅 Display 机型；selector 交给会话托管设备等待/切换
        let selector = AutoDeviceSelector(wearables: Wearables.shared) { candidate in
            candidate.supportsDisplay()
        }
        deviceSelector = selector
        do {
            let session = try Wearables.shared.createSession(deviceSelector: selector)
            self.session = session
            try session.start()
            observeSession(session)
            observeThermal(following: selector)
        } catch {
            self.session = nil
            throw mapSessionError(error)
        }
    }

    public func stop() async {
        stopCameraObservation()
        stopDisplayObservation()
        thermalTask?.cancel()
        thermalTask = nil
        for task in observationTasks { task.cancel() }
        observationTasks = []
        display?.stop()
        display = nil
        cameraStream = nil
        session?.stop()
        session = nil
        deviceSelector = nil
        publishSession(.stopped)
    }

    // MARK: - 相机能力

    public func attachCamera(preset: CameraPreset) async throws {
        guard let session else { throw GlassesSessionError.sessionNotStarted }
        guard cameraStream == nil else { return }
        publishCamera(.waitingForDevice)
        // raw codec（研究文档 §8.1——直接 CMSampleBuffer 入 HaishinKit mixer，无重解码）
        let configuration = StreamConfiguration(
            videoCodec: .raw,
            resolution: mapResolution(preset.quality),
            frameRate: UInt(preset.frameRate)
        )
        let stream: MWDATCamera.Stream?
        do {
            stream = try session.addStream(config: configuration)
        } catch {
            publishCamera(.stopped)
            throw mapSessionError(error)
        }
        guard let stream else {
            publishCamera(.stopped)
            // 0.8.0 接口未定义 addStream 返回 nil 的语义，按设备不可达处理
            throw GlassesSessionError.notConnected
        }
        cameraStream = stream
        observeCamera(stream)
        stream.start()   // 同步；后续状态（starting→streaming）经 statePublisher 回流
    }

    public func detachCamera() async {
        stopCameraObservation()
        if let cameraStream {
            publishCamera(.stopping)
            cameraStream.stop()
        }
        cameraStream = nil
        publishCamera(.stopped)
    }

    // MARK: - Display 能力

    public func attachDisplay() async throws {
        guard let session else { throw GlassesSessionError.sessionNotStarted }
        guard display == nil else { return }
        displayDetachRequested = false
        do {
            // 一个 session 同时只能挂一个 display capability（先 remove 再 add 由上层保证）
            let display = try session.addDisplay()
            self.display = display
            observeDisplay(display)
            display.start()   // 同步；状态经 statePublisher 回流
        } catch {
            self.display = nil
            // addDisplay 抛的是会话级 DeviceSessionError（capabilityAlreadyActive 等）
            throw mapSessionError(error)
        }
    }

    public func detachDisplay() async {
        displayDetachRequested = true
        stopDisplayObservation()
        if let display {
            publishDisplay(.stopping)
            display.stop()
        }
        display = nil
        publishDisplay(.stopped)
    }

    public func sendDisplayPayload(_ payload: DisplayPayload) async throws {
        guard let display else { throw GlassesSessionError.displayNotAttached }
        // DisplayPayload 携带 canonicalJSON（GlassNode 的稳定序列化）→ 还原后翻译成 DAT 组件树
        let node: GlassNode
        do {
            node = try JSONDecoder().decode(GlassNode.self, from: Data(payload.canonicalJSON.utf8))
        } catch {
            throw GlassesSessionError.rendering("payload 解码失败: \(error)")
        }
        let root = translate(node)
        // send 只接受 DisplayableView（FlexBox/VideoPlayer）；非 FlexBox 根节点包一层
        let rootBox = root as? MWDATDisplay.FlexBox ?? MWDATDisplay.FlexBox { root }
        do {
            // send 为整屏替换；20s 变暗/25s 休眠不结束会话，唤醒后可复用旧内容
            try await display.send(rootBox)
        } catch {
            throw mapDisplayError(error)
        }
    }

    public func clearDisplay() async throws {
        guard let display else { throw GlassesSessionError.displayNotAttached }
        do {
            try await display.clearDisplay()
        } catch {
            throw mapDisplayError(error)
        }
    }

    // MARK: - GlassNode → MWDATDisplay 组件翻译

    /// 契约布局树与 DAT FlexBox DSL 同构，逐节点直译
    /// （children 经 ComponentBuilder 的 for-in/buildArray 注入）。
    private func translate(_ node: GlassNode) -> any MWDATDisplay.ViewComponent {
        switch node {
        case let .flexBox(props, children):
            let translated = children.map { translate($0) }
            var box = MWDATDisplay.FlexBox(
                direction: translateDirection(props.direction),
                spacing: CGFloat(props.gap),
                alignment: translateAlignment(props.alignment),
                crossAlignment: translateAlignment(props.crossAlignment),
                padding: MWDATDisplay.EdgeInsets(all: CGFloat(props.padding))
            ) {
                for child in translated { child }
            }
            if let actionID = props.actionID {
                box = box.onTap(makeClickHandler(actionID: actionID))
            }
            return box

        case let .text(content, style, color):
            return MWDATDisplay.Text(
                content,
                style: translateTextStyle(style),
                color: translateTextColor(color)
            )

        case let .image(url):
            return MWDATDisplay.Image(uri: url, sizePreset: .fill, cornerRadius: .none)

        case let .button(label, style, actionID):
            return MWDATDisplay.Button(
                label: label,
                style: translateButtonStyle(style),
                onClick: makeClickHandler(actionID: actionID)
            )

        case let .icon(name):
            return MWDATDisplay.Icon(name: translateIcon(name), style: .outline)
        }
    }

    /// 任何组件点击 → captouch .tap（契约手势流）+ actionID（补充流）
    private func makeClickHandler(actionID: String) -> @Sendable () -> Void {
        let captouchBus = self.captouchBus
        let actionBus = self.actionBus
        return {
            captouchBus.send(.tap)
            actionBus.send(actionID)
        }
    }

    private func translateDirection(_ direction: GlassDirection) -> MWDATDisplay.Direction {
        switch direction {
        case .column: return .column
        case .row: return .row
        }
    }

    private func translateAlignment(_ alignment: GlassAlignment) -> MWDATDisplay.Alignment {
        switch alignment {
        case .start: return .start
        case .center: return .center
        case .end: return .end
        case .stretch: return .stretch
        }
    }

    private func translateTextStyle(_ style: GlassTextStyle) -> MWDATDisplay.TextStyle {
        switch style {
        case .heading: return .heading
        case .body: return .body
        case .meta: return .meta
        }
    }

    private func translateTextColor(_ color: GlassTextColor) -> MWDATDisplay.TextColor {
        switch color {
        case .primary: return .primary
        case .secondary: return .secondary
        }
    }

    private func translateButtonStyle(_ style: GlassButtonStyle) -> MWDATDisplay.ButtonStyle {
        switch style {
        case .primary: return .primary
        case .secondary: return .secondary
        case .outline: return .outline
        }
    }

    private func translateIcon(_ name: GlassIconName) -> MWDATDisplay.IconName {
        switch name {
        case .checkmarkCircle: return .checkmarkCircle
        case .bell: return .bell
        case .gear: return .gear
        case .heart: return .heart
        case .star: return .star
        case .arrowLeft: return .arrowLeft
        case .arrowRight: return .arrowRight
        case .gift: return .shoppingBag               // 0.8.0 无 gift，用 shoppingBag 近似
        case .warning: return .exclamationTriangle    // 0.8.0 无 warning，用 exclamationTriangle 近似
        }
    }

    // MARK: - SDK 状态观察

    /// Announcer（listen/token 回调）→ AsyncStream；流终止时异步取消订阅 token
    private func makeStream<T: Sendable>(from announcer: any Announcer<T>) -> AsyncStream<T> {
        AsyncStream { continuation in
            let token = announcer.listen { value in
                continuation.yield(value)
            }
            continuation.onTermination = { _ in
                Task { await token.cancel() }
            }
        }
    }

    private func observeSession(_ session: DeviceSession) {
        let states = session.stateStream()
        observationTasks.append(Task { [weak self] in
            for await state in states {
                guard let self else { return }
                await self.handleSessionState(state)
            }
        })
        // 会话级错误（热/电/DAT app 版本等）→ 契约故障
        let errors = session.errorStream()
        observationTasks.append(Task { [weak self] in
            for await error in errors {
                guard let self else { return }
                await self.handleSessionError(error)
            }
        })
    }

    /// 设备健康（ThermalLevel）挂在设备标识符上；AutoDeviceSelector 切换设备时跟随重挂
    private func observeThermal(following selector: AutoDeviceSelector) {
        let deviceIDs = selector.activeDeviceStream()
        observationTasks.append(Task { [weak self] in
            for await deviceID in deviceIDs {
                guard let self else { return }
                await self.restartThermalObservation(deviceID)
            }
        })
    }

    private func restartThermalObservation(_ deviceID: DeviceIdentifier?) {
        thermalTask?.cancel()
        thermalTask = nil
        guard let deviceID else { return }
        let states = Wearables.shared.deviceStateStream(for: deviceID)
        thermalTask = Task { [weak self] in
            for await state in states {
                guard let self else { return }
                await self.publishThermal(self.mapThermal(state.thermalLevel))
            }
        }
    }

    private func observeDisplay(_ display: MWDATDisplay.Display) {
        let states = makeStream(from: display.statePublisher)
        displayTask = Task { [weak self] in
            for await state in states {
                guard let self else { return }
                await self.handleDisplayState(state)
            }
        }
    }

    private func observeCamera(_ stream: MWDATCamera.Stream) {
        let states = makeStream(from: stream.statePublisher)
        cameraTasks.append(Task { [weak self] in
            for await state in states {
                guard let self else { return }
                await self.publishCamera(self.mapCameraState(state))
            }
        })
        // 帧流；sequence 由适配器自编号（契约只要求单调）
        let frames = makeStream(from: stream.videoFramePublisher)
        cameraTasks.append(Task { [weak self] in
            for await frame in frames {
                guard let self else { return }
                await self.publishFrame(frame)
            }
        })
    }

    private func stopCameraObservation() {
        for task in cameraTasks { task.cancel() }
        cameraTasks = []
    }

    private func stopDisplayObservation() {
        displayTask?.cancel()
        displayTask = nil
    }

    // MARK: - 状态/事件处理

    private func handleSessionState(_ state: DeviceSessionState) {
        let mapped = mapSessionState(state)
        publishSession(mapped)
        if mapped == .paused {
            // 来电等系统优先事件抢占（display-capabilities.md §2）
            faultBus.send(.systemInterrupted)
        }
        if mapped == .stopped && lastKnownSessionState == .started {
            // 会话意外终止：按蓝牙断连处理，交给 GlassesReconnectManager 退避重连
            faultBus.send(.bluetoothLost)
        }
        lastKnownSessionState = mapped
    }

    private func handleDisplayState(_ state: MWDATDisplay.DisplayState) {
        let mapped = mapDisplayState(state)
        // TODO(真机核验)：back 手势在 L0 结束 display 会话且 SDK 无独立回调——
        // 以"非主动 detach、session 仍 started 时 display 走向 stopped"合成 .backOnRoot
        if mapped == .stopped, !displayDetachRequested, lastKnownSessionState == .started,
           lastKnownDisplayState == .started {
            captouchBus.send(.backOnRoot)
        }
        lastKnownDisplayState = mapped
        publishDisplay(mapped)
    }

    private func handleSessionError(_ error: DeviceSessionError) {
        guard let fault = mapSessionFault(error) else { return }
        faultBus.send(fault)
    }

    private func publishFrame(_ frame: MWDATCamera.VideoFrame) {
        frameSequence += 1
        frameBus.send(CameraFramePacket(
            sequence: frameSequence,
            timestamp: Date(),
            payload: DATCameraFramePayload(sampleBuffer: frame.sampleBuffer)
        ))
    }

    private func publishSession(_ state: GlassesSessionState) { sessionBus.send(state) }
    private func publishDisplay(_ state: GlassesKit.DisplayState) { displayBus.send(state) }
    private func publishCamera(_ state: CameraStreamState) { cameraBus.send(state) }
    private func publishThermal(_ level: GlassesKit.ThermalLevel) { thermalBus.send(level) }

    // MARK: - SDK ↔ 契约映射

    private func mapSessionState(_ state: DeviceSessionState) -> GlassesSessionState {
        switch state {
        case .idle: return .idle
        case .starting: return .starting
        case .started: return .started
        case .paused: return .paused
        case .stopping: return .stopping
        case .stopped: return .stopped
        }
    }

    private func mapDisplayState(_ state: MWDATDisplay.DisplayState) -> GlassesKit.DisplayState {
        switch state {
        case .stopped: return .stopped
        case .starting: return .starting
        case .started: return .started
        case .stopping: return .stopping
        }
    }

    private func mapCameraState(_ state: MWDATCamera.StreamState) -> CameraStreamState {
        switch state {
        case .stopped: return .stopped
        case .waitingForDevice: return .waitingForDevice
        case .starting: return .starting
        case .streaming: return .streaming
        case .paused: return .paused
        case .stopping: return .stopping
        }
    }

    /// 契约 pixelSize 三档（720×1280/504×896/360×640）与 SDK 预设枚举一致，按 quality 直映
    private func mapResolution(_ quality: CameraPreset.Quality) -> MWDATCamera.StreamingResolution {
        switch quality {
        case .high: return .high
        case .medium: return .medium
        case .low: return .low
        }
    }

    /// SDK 8 档 → 契约 4 档区间归并
    private func mapThermal(_ level: MWDATCore.ThermalLevel) -> GlassesKit.ThermalLevel {
        switch level {
        case .unknown, .none: return .normal
        case .light, .moderate: return .warm
        case .severe: return .hot
        case .critical, .emergency, .shutdown: return .critical
        }
    }

    /// 会话错误流 → 契约故障；API 使用类错误（session*/capability*）不是运行时故障，返回 nil 不上报
    private func mapSessionFault(_ error: DeviceSessionError) -> GlassesFault? {
        switch error {
        case .thermalCritical, .thermalEmergency:
            return .thermal(.critical)
        case .batteryCritical, .peakPowerShutdown:
            return .batteryCritical
        case .datAppOnTheGlassesUpdateRequired, .dwaUnavailable:
            // dwaUnavailable：眼镜端 DAT app 不可用，与"需要更新"同一处置路径
            return .datAppUpdateRequired
        case .noEligibleDevice:
            return .bluetoothLost
        case .unexpectedError:
            // 无更细分类：按断连交给重连管理器兜底
            return .bluetoothLost
        case .sessionAlreadyStopped, .sessionAlreadyExists, .sessionIdle,
             .capabilityAlreadyActive, .capabilityNotFound:
            return nil
        }
    }

    /// display 错误分类——断连类进 GlassesSessionError.notConnected
    /// （DisplayDispatcher 据 isDisconnection 缓存待重挂重发），其余按渲染失败丢帧。
    private func mapDisplayError(_ error: any Error) -> GlassesSessionError {
        if let displayError = error as? MWDATDisplay.DisplayError {
            switch displayError {
            case .deviceDisconnected, .connectionNotAvailable, .deviceNotFound:
                return .notConnected
            case .invalidVideoURL:
                return .rendering("invalidVideoURL")
            case let .displayError(message):
                return .rendering(message)
            @unknown default:
                return .underlying(String(describing: displayError))
            }
        }
        return .underlying(String(describing: error))
    }

    private func mapSessionError(_ error: any Error) -> GlassesSessionError {
        if let sessionError = error as? DeviceSessionError {
            switch sessionError {
            case .noEligibleDevice:
                return .notConnected
            case .sessionIdle, .sessionAlreadyStopped:
                return .sessionNotStarted
            case .thermalCritical, .thermalEmergency, .batteryCritical, .peakPowerShutdown,
                 .datAppOnTheGlassesUpdateRequired, .dwaUnavailable,
                 .sessionAlreadyExists, .capabilityAlreadyActive, .capabilityNotFound,
                 .unexpectedError:
                return .underlying(String(describing: sessionError))
            }
        }
        return .underlying(String(describing: error))
    }
}
#endif
