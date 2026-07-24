// DATGlassesSessionAdapter —— 真实 Meta Wearables DAT SDK (0.8.0) → GlassesSessionProviding 适配。
// 本文件只随 App target（xcodegen 工程）编译，不参与 swift build；整文件由 canImport 守护。
// ⚠️ 真机验证项见研究文档 §7（steven-ai-lab 任务目录 research-live-danmaku.md 第 7 节）：
//    同会话 addStream+addDisplay 共存、休眠中 send 行为、1Hz send 稳定性、热/续航曲线等。
//
// ── API 映射假设（依据 display-capabilities.md@2026-07-24，集成时逐条对照 SDK 核验）──
//  A1  入口：`Wearables.configure()` 幂等初始化（DAM 模型由 Info.plist `MWDAT.DAMEnabled` 开启）；
//      设备发现走 `AutoDeviceSelector`，以 `Device.supportsDisplay()` 过滤 Display 机型。
//  A2  会话：`Wearables.shared.createSession(for:)` → `DeviceSession`；`session.start()/stop()`；
//      状态流假设为 `session.stateStream: AsyncStream<DeviceSessionState>`（文档只确认"可观察"）。
//  A3  相机：`session.addStream(StreamConfiguration)` 返回流能力对象；
//      `StreamConfiguration(resolution:frameRate:videoCodec: .raw)`（研究文档 §8.1：VideoFrame 自带
//      raw CMSampleBuffer）；帧流假设为 `stream.frames: AsyncStream<VideoFrame>`。
//  A4  屏显：`session.addDisplay(DisplayConfiguration())` 返回 display 能力对象；0.8.0 iOS
//      `display.start()/stop()` 为同步；发送为 `display.send(_:)`（iOS 名，Android 为 sendContent）；
//      0.8.0 新增 `display.clearDisplay()`。
//  A5  组件：`MWDATDisplay.FlexBox/Text/Button/Image/Icon`（与 SwiftUI 同名冲突，故本文件不 import
//      SwiftUI 并全程 MWDATDisplay. 限定）；文本 3 样式 heading/body/meta × 2 色 primary/secondary；
//      FlexBox 支持 direction/gap/alignment/crossAlignment/逐边 padding/onClick。
//  A6  枚举拼写：假设 Swift 侧为 lowerCamel（.column/.row、.start/.center/.end/.stretch、
//      .heading/.body/.meta、.primary/.secondary）；Padding 假设有 `Padding(all:)` 便捷构造。
//  A7  Icon：契约 9 个图标名假设与官方 icon catalog 同名（catalog 100+，需逐个核对；
//      对不上的用自定义 Image 兜底——见 translateIcon TODO）。
//  A8  交互：captouch 单指 tap 以组件 onClick 回调抽象（无全局 tap 流）；本适配器把任何
//      onClick 归一为 captouch .tap + displayActions(actionID) 两条流。back 手势无独立回调：
//      L0 上 back 直接结束 display 会话 → 以"display 意外 stopped 且 session 仍 started"
//      启发式合成 .backOnRoot（需真机核验，见 TODO）。
//  A9  健康：`Wearables.shared.deviceStateStream(for:)` 暴露 ThermalLevel（normal/warm/hot/critical
//      拼写待核）；会话级错误流假设为 `session.errors: AsyncStream<DeviceSessionError>`，其中
//      THERMAL_CRITICAL/BATTERY_CRITICAL/PEAK_POWER_SHUTDOWN/DAT_APP_..._UPDATE_REQUIRED 映射契约故障。
//  A10 错误：`DisplayError.deviceDisconnected/.connectionNotAvailable/.deviceNotFound` 归为断连
//      （GlassesSessionError.notConnected → DisplayDispatcher 缓存重发）；其余归渲染/未知（丢帧）。
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
    private let displayBus = StreamBroadcaster<DisplayState>(replaysLatest: true)
    private let cameraBus = StreamBroadcaster<CameraStreamState>(replaysLatest: true)
    private let thermalBus = StreamBroadcaster<ThermalLevel>(replaysLatest: true)
    private let faultBus = StreamBroadcaster<GlassesFault>()
    private let captouchBus = StreamBroadcaster<CaptouchGesture>()
    private let frameBus = StreamBroadcaster<CameraFramePacket>()
    /// 契约缺口补充：captouch 流不带 tap 区域信息，组件级 onClick 的 actionID 走本流
    private let actionBus = StreamBroadcaster<String>()

    // MARK: - SDK 句柄

    private var device: Device?
    private var session: DeviceSession?
    private var cameraStream: CameraStreamCapability?
    private var display: DisplayCapability?

    private var observationTasks: [Task<Void, Never>] = []
    private var frameTask: Task<Void, Never>?
    private var frameSequence: UInt64 = 0

    private var lastKnownSessionState: GlassesSessionState = .idle
    private var lastKnownDisplayState: DisplayState = .stopped
    private var displayDetachRequested = false

    public init() {}

    // MARK: - GlassesSessionProviding：流

    public nonisolated var sessionStates: AsyncStream<GlassesSessionState> { sessionBus.subscribe() }
    public nonisolated var displayStates: AsyncStream<DisplayState> { displayBus.subscribe() }
    public nonisolated var cameraStates: AsyncStream<CameraStreamState> { cameraBus.subscribe() }
    public nonisolated var thermal: AsyncStream<ThermalLevel> { thermalBus.subscribe() }
    public nonisolated var faults: AsyncStream<GlassesFault> { faultBus.subscribe() }
    public nonisolated var captouch: AsyncStream<CaptouchGesture> { captouchBus.subscribe() }
    public nonisolated var cameraFrames: AsyncStream<CameraFramePacket> { frameBus.subscribe() }

    /// 组件 onClick 的 actionID 流（契约外补充；SessionCoordinator 据此驱动
    /// DanmakuFilterMachine.handle(.tap(actionID:)) 等）
    public nonisolated var displayActions: AsyncStream<String> { actionBus.subscribe() }

    // MARK: - GlassesSessionProviding：生命周期

    public func start() async throws {
        guard session == nil else { return }
        // A1：初始化 + 设备发现（仅 Display 机型）
        Wearables.configure()
        let selector = AutoDeviceSelector(filter: { candidate in candidate.supportsDisplay() })
        let device: Device
        do {
            device = try await selector.selectDevice()
        } catch {
            throw GlassesSessionError.notConnected
        }
        self.device = device

        // A2：建会话并启动
        do {
            let session = try await Wearables.shared.createSession(for: device)
            self.session = session
            try await session.start()
            observeSession(session)
            observeDeviceState(device)
        } catch {
            self.session = nil
            throw mapSessionError(error)
        }
    }

    public func stop() async {
        stopFrameObservation()
        for task in observationTasks { task.cancel() }
        observationTasks = []
        if let display { try? display.stop() }
        display = nil
        cameraStream = nil
        if let session { await session.stop() }
        session = nil
        device = nil
        publishSession(.stopped)
    }

    // MARK: - 相机能力

    public func attachCamera(preset: CameraPreset) async throws {
        guard let session else { throw GlassesSessionError.sessionNotStarted }
        guard cameraStream == nil else { return }
        publishCamera(.waitingForDevice)
        // A3：raw codec（研究文档 §8.1——直接 CMSampleBuffer 入 HaishinKit mixer，无重解码）
        let size = preset.pixelSize
        let configuration = StreamConfiguration(
            resolution: StreamConfiguration.Resolution(width: size.width, height: size.height),
            frameRate: preset.frameRate,
            videoCodec: .raw
        )
        do {
            let stream = try await session.addStream(configuration)
            cameraStream = stream
            try await stream.start()
            publishCamera(.streaming)
            observeFrames(of: stream)
        } catch {
            publishCamera(.stopped)
            throw mapSessionError(error)
        }
    }

    public func detachCamera() async {
        stopFrameObservation()
        if let cameraStream {
            publishCamera(.stopping)
            try? await cameraStream.stop()
            // 0.8.0 capability 生命周期简化：Closeable / stop() 即从会话移除
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
            // A4：一个 session 同时只能挂一个 display capability（先 remove 再 add 由上层保证）
            let display = try await session.addDisplay(DisplayConfiguration())
            self.display = display
            try display.start()   // 0.8.0 iOS 同步
            observeDisplay(display)
        } catch {
            self.display = nil
            throw mapDisplayError(error)
        }
    }

    public func detachDisplay() async {
        displayDetachRequested = true
        if let display {
            publishDisplay(.stopping)
            try? display.stop()
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
        do {
            // A4：send 为整屏替换；20s 变暗/25s 休眠不结束会话，唤醒后可复用旧内容
            try await display.send(root)
        } catch {
            throw mapDisplayError(error)
        }
    }

    public func clearDisplay() async throws {
        guard let display else { throw GlassesSessionError.displayNotAttached }
        do {
            try await display.clearDisplay()   // 0.8.0 新增
        } catch {
            throw mapDisplayError(error)
        }
    }

    // MARK: - GlassNode → MWDATDisplay 组件翻译

    /// 契约布局树与 DAT FlexBox DSL 同构，逐节点直译。
    /// A5/A6：组件构造器签名与枚举拼写为假设，集成时以 SDK 头文件为准。
    private func translate(_ node: GlassNode) -> MWDATDisplay.Component {
        switch node {
        case let .flexBox(props, children):
            var box = MWDATDisplay.FlexBox(
                direction: translateDirection(props.direction),
                gap: props.gap,
                alignment: translateAlignment(props.alignment),
                crossAlignment: translateAlignment(props.crossAlignment),
                padding: MWDATDisplay.Padding(all: props.padding),
                children: children.map { translate($0) }
            )
            if let actionID = props.actionID {
                box.onClick = makeClickHandler(actionID: actionID)
            }
            return box

        case let .text(content, style, color):
            return MWDATDisplay.Text(
                content,
                style: translateTextStyle(style),
                color: translateTextColor(color)
            )

        case let .image(url):
            // A5：Image 仅支持 URL 加载；尺寸预设 ICON/FILL、圆角 NONE/SMALL/MEDIUM
            return MWDATDisplay.Image(url: url, size: .fill, cornerRadius: .none)

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

    /// A8：任何组件点击 → captouch .tap（契约手势流）+ actionID（补充流）
    private func makeClickHandler(actionID: String) -> @Sendable () -> Void {
        let captouchBus = self.captouchBus
        let actionBus = self.actionBus
        return {
            captouchBus.send(.tap)
            actionBus.send(actionID)
        }
    }

    private func translateDirection(_ direction: GlassDirection) -> MWDATDisplay.FlexDirection {
        switch direction {
        case .column: return .column
        case .row: return .row
        }
    }

    private func translateAlignment(_ alignment: GlassAlignment) -> MWDATDisplay.FlexAlignment {
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

    /// A7 TODO(集成)：逐个核对官方 icon catalog（/docs/develop/dat/display-icons）命名；
    /// 目录里没有的用自定义 Image 兜底。
    private func translateIcon(_ name: GlassIconName) -> MWDATDisplay.IconName {
        switch name {
        case .checkmarkCircle: return .checkmarkCircle
        case .bell: return .bell
        case .gear: return .gear
        case .heart: return .heart
        case .star: return .star
        case .arrowLeft: return .arrowLeft
        case .arrowRight: return .arrowRight
        case .gift: return .gift
        case .warning: return .warning
        }
    }

    // MARK: - SDK 状态观察

    private func observeSession(_ session: DeviceSession) {
        // A2：会话状态流
        let states = session.stateStream
        observationTasks.append(Task { [weak self] in
            for await state in states {
                guard let self else { return }
                await self.handleSessionState(state)
            }
        })
        // A9：会话级错误 → 契约故障
        let errors = session.errors
        observationTasks.append(Task { [weak self] in
            for await error in errors {
                guard let self else { return }
                await self.handleSessionError(error)
            }
        })
    }

    private func observeDeviceState(_ device: Device) {
        // A9：设备健康（ThermalLevel）
        let states = Wearables.shared.deviceStateStream(for: device)
        observationTasks.append(Task { [weak self] in
            for await state in states {
                guard let self else { return }
                await self.publishThermal(self.mapThermal(state.thermalLevel))
            }
        })
    }

    private func observeDisplay(_ display: DisplayCapability) {
        let states = display.stateStream
        observationTasks.append(Task { [weak self] in
            for await state in states {
                guard let self else { return }
                await self.handleDisplayState(state)
            }
        })
    }

    private func observeFrames(of stream: CameraStreamCapability) {
        // A3：帧流；sequence 由适配器自编号（契约只要求单调）
        let frames = stream.frames
        frameTask = Task { [weak self] in
            for await frame in frames {
                guard let self else { return }
                await self.publishFrame(frame)
            }
        }
    }

    private func stopFrameObservation() {
        frameTask?.cancel()
        frameTask = nil
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
        // A8 TODO(真机核验)：back 手势在 L0 结束 display 会话且 SDK 无独立回调——
        // 以"非主动 detach、session 仍 started 时 display 走向 stopped"合成 .backOnRoot
        if mapped == .stopped, !displayDetachRequested, lastKnownSessionState == .started,
           lastKnownDisplayState == .started {
            captouchBus.send(.backOnRoot)
        }
        lastKnownDisplayState = mapped
        publishDisplay(mapped)
    }

    private func handleSessionError(_ error: DeviceSessionError) {
        faultBus.send(mapSessionFault(error))
    }

    private func publishFrame(_ frame: VideoFrame) {
        frameSequence += 1
        frameBus.send(CameraFramePacket(
            sequence: frameSequence,
            timestamp: Date(),
            payload: DATCameraFramePayload(sampleBuffer: frame.sampleBuffer)
        ))
    }

    private func publishSession(_ state: GlassesSessionState) { sessionBus.send(state) }
    private func publishDisplay(_ state: DisplayState) { displayBus.send(state) }
    private func publishCamera(_ state: CameraStreamState) { cameraBus.send(state) }
    private func publishThermal(_ level: ThermalLevel) { thermalBus.send(level) }

    // MARK: - SDK ↔ 契约映射

    private func mapSessionState(_ state: DeviceSessionState) -> GlassesSessionState {
        switch state {
        case .idle: return .idle
        case .starting: return .starting
        case .started: return .started
        case .paused: return .paused
        case .stopping: return .stopping
        case .stopped: return .stopped
        @unknown default: return .stopped
        }
    }

    private func mapDisplayState(_ state: MWDATDisplay.DisplayState) -> DisplayState {
        switch state {
        case .stopped: return .stopped
        case .starting: return .starting
        case .started: return .started
        case .stopping: return .stopping
        @unknown default: return .stopped
        }
    }

    private func mapThermal(_ level: MWDATCore.ThermalLevel) -> ThermalLevel {
        switch level {
        case .normal: return .normal
        case .warm: return .warm
        case .hot: return .hot
        case .critical: return .critical
        @unknown default: return .critical
        }
    }

    private func mapSessionFault(_ error: DeviceSessionError) -> GlassesFault {
        switch error {
        case .thermalCritical, .thermalEmergency: return .thermal(.critical)
        case .batteryCritical, .peakPowerShutdown: return .batteryCritical
        case .datAppOnTheGlassesUpdateRequired: return .datAppUpdateRequired
        @unknown default: return .bluetoothLost
        }
    }

    /// A10：display 错误分类——断连类进 GlassesSessionError.notConnected
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
            case .capabilityDenied: return .capabilityDenied
            case .deviceDisconnected: return .notConnected
            case .invalidSessionState: return .sessionNotStarted
            @unknown default: return .underlying(String(describing: sessionError))
            }
        }
        return .underlying(String(describing: error))
    }
}
#endif
