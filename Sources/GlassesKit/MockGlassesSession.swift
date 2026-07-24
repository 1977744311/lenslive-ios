// 可脚本化 Mock 会话 —— M0 全链路联调核心件。
// 能力：
//   1. API 调用自动产生贴近真实 DAT 的状态迁移（start → .starting/.started 等）；
//   2. 任意注入状态/热等级/故障/captouch 手势（simulate* / inject* 系列）；
//   3. 相机帧节拍器：attachCamera 后按 preset.frameRate 用注入时钟产帧；
//   4. 记录全部调用（operations，含失败调用）与成功送达的负载（sentPayloads），
//      供断言与"断连恢复后重发最后一屏"验证。
import Foundation

public actor MockGlassesSession: GlassesSessionProviding {

    /// 调用日志条目：按调用时点记录（不区分成败；成败看 sentPayloads / 抛错）
    public enum MockOperation: Sendable, Equatable {
        case start
        case stop
        case attachCamera(CameraPreset)
        case detachCamera
        case attachDisplay
        case detachDisplay
        case sendDisplayPayload(DisplayPayload)
        case clearDisplay
    }

    // MARK: - 存储

    private let clock: any GlassesClocking

    private let sessionBus = StreamBroadcaster<GlassesSessionState>(replaysLatest: true)
    private let displayBus = StreamBroadcaster<DisplayState>(replaysLatest: true)
    private let cameraBus = StreamBroadcaster<CameraStreamState>(replaysLatest: true)
    private let thermalBus = StreamBroadcaster<ThermalLevel>(replaysLatest: true)
    private let faultBus = StreamBroadcaster<GlassesFault>()
    private let captouchBus = StreamBroadcaster<CaptouchGesture>()
    private let frameBus = StreamBroadcaster<CameraFramePacket>()

    public private(set) var currentSessionState: GlassesSessionState = .idle
    public private(set) var currentDisplayState: DisplayState = .stopped
    public private(set) var currentCameraState: CameraStreamState = .stopped

    public private(set) var sentPayloads: [DisplayPayload] = []
    public private(set) var operations: [MockOperation] = []

    // 脚本旋钮
    private var reachable = true
    private var pendingStartFailures = 0
    private var nextSendFailure: GlassesSessionError?

    private var frameTask: Task<Void, Never>?
    private var frameSequence: UInt64 = 0

    public init(clock: any GlassesClocking = GlassesSystemClock()) {
        self.clock = clock
    }

    // MARK: - GlassesSessionProviding：流

    public nonisolated var sessionStates: AsyncStream<GlassesSessionState> { sessionBus.subscribe() }
    public nonisolated var displayStates: AsyncStream<DisplayState> { displayBus.subscribe() }
    public nonisolated var cameraStates: AsyncStream<CameraStreamState> { cameraBus.subscribe() }
    public nonisolated var thermal: AsyncStream<ThermalLevel> { thermalBus.subscribe() }
    public nonisolated var faults: AsyncStream<GlassesFault> { faultBus.subscribe() }
    public nonisolated var captouch: AsyncStream<CaptouchGesture> { captouchBus.subscribe() }
    public nonisolated var cameraFrames: AsyncStream<CameraFramePacket> { frameBus.subscribe() }

    // MARK: - GlassesSessionProviding：操作

    public func start() async throws {
        operations.append(.start)
        if pendingStartFailures > 0 {
            pendingStartFailures -= 1
            throw GlassesSessionError.notConnected
        }
        guard reachable else { throw GlassesSessionError.notConnected }
        setSession(.starting)
        setSession(.started)
    }

    public func stop() async {
        operations.append(.stop)
        stopFrameTicker()
        if currentCameraState != .stopped {
            setCamera(.stopping)
            setCamera(.stopped)
        }
        if currentDisplayState != .stopped {
            setDisplay(.stopping)
            setDisplay(.stopped)
        }
        setSession(.stopping)
        setSession(.stopped)
    }

    public func attachCamera(preset: CameraPreset) async throws {
        operations.append(.attachCamera(preset))
        guard reachable else { throw GlassesSessionError.notConnected }
        guard currentSessionState == .started else { throw GlassesSessionError.sessionNotStarted }
        setCamera(.starting)
        setCamera(.streaming)
        startFrameTicker(preset: preset)
    }

    public func detachCamera() async {
        operations.append(.detachCamera)
        stopFrameTicker()
        if currentCameraState != .stopped {
            setCamera(.stopping)
            setCamera(.stopped)
        }
    }

    public func attachDisplay() async throws {
        operations.append(.attachDisplay)
        guard reachable else { throw GlassesSessionError.notConnected }
        guard currentSessionState == .started else { throw GlassesSessionError.sessionNotStarted }
        setDisplay(.starting)
        setDisplay(.started)
    }

    public func detachDisplay() async {
        operations.append(.detachDisplay)
        if currentDisplayState != .stopped {
            setDisplay(.stopping)
            setDisplay(.stopped)
        }
    }

    public func sendDisplayPayload(_ payload: DisplayPayload) async throws {
        operations.append(.sendDisplayPayload(payload))
        if let failure = nextSendFailure {
            nextSendFailure = nil
            throw failure
        }
        guard reachable, currentSessionState == .started else { throw GlassesSessionError.notConnected }
        guard currentDisplayState == .started else { throw GlassesSessionError.displayNotAttached }
        sentPayloads.append(payload)
    }

    public func clearDisplay() async throws {
        operations.append(.clearDisplay)
        guard reachable, currentSessionState == .started else { throw GlassesSessionError.notConnected }
        guard currentDisplayState == .started else { throw GlassesSessionError.displayNotAttached }
    }

    // MARK: - 脚本注入

    /// 蓝牙断连剧本：发 fault、全部能力态归零、停帧、后续调用统统 notConnected，
    /// 直到 setReachable(true)。
    public func simulateBluetoothLoss() {
        reachable = false
        stopFrameTicker()
        faultBus.send(.bluetoothLost)
        if currentCameraState != .stopped { setCamera(.stopped) }
        if currentDisplayState != .stopped { setDisplay(.stopped) }
        if currentSessionState != .stopped { setSession(.stopped) }
    }

    public func setReachable(_ flag: Bool) { reachable = flag }

    /// 让接下来 n 次 start() 直接抛 notConnected（退避重连测试用）
    public func failNextStarts(_ n: Int) { pendingStartFailures = n }

    /// 让下一次 sendDisplayPayload 抛指定错误（节流器失败分类测试用）
    public func failNextSend(_ error: GlassesSessionError) { nextSendFailure = error }

    public func injectSessionState(_ state: GlassesSessionState) { setSession(state) }
    public func injectDisplayState(_ state: DisplayState) { setDisplay(state) }
    public func injectCameraState(_ state: CameraStreamState) { setCamera(state) }
    public func injectThermal(_ level: ThermalLevel) { thermalBus.send(level) }
    public func injectFault(_ fault: GlassesFault) { faultBus.send(fault) }
    public func injectGesture(_ gesture: CaptouchGesture) { captouchBus.send(gesture) }

    // MARK: - 断言辅助

    public var lastPayload: DisplayPayload? { sentPayloads.last }

    public func resetRecords() {
        sentPayloads = []
        operations = []
    }

    // MARK: - 内部

    private func setSession(_ state: GlassesSessionState) {
        guard state != currentSessionState else { return }
        currentSessionState = state
        sessionBus.send(state)
    }

    private func setDisplay(_ state: DisplayState) {
        guard state != currentDisplayState else { return }
        currentDisplayState = state
        displayBus.send(state)
    }

    private func setCamera(_ state: CameraStreamState) {
        guard state != currentCameraState else { return }
        currentCameraState = state
        cameraBus.send(state)
    }

    private func startFrameTicker(preset: CameraPreset) {
        stopFrameTicker()
        let interval = 1.0 / Double(max(preset.frameRate, 1))
        frameTask = Task { [weak self, clock] in
            while !Task.isCancelled {
                do { try await clock.sleep(seconds: interval) } catch { return }
                guard let self else { return }
                await self.emitFrame()
            }
        }
    }

    private func stopFrameTicker() {
        frameTask?.cancel()
        frameTask = nil
    }

    private func emitFrame() {
        guard currentCameraState == .streaming else { return }
        frameSequence += 1
        frameBus.send(CameraFramePacket(sequence: frameSequence, timestamp: clock.now))
    }
}
