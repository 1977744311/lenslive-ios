// GlassesKit 契约 —— DAT SDK 的唯一抽象边界。
// 真实 DAT 适配器位于 App/Adapters/GlassesDAT/（canImport(MWDATCore) 守护）；
// 本库内提供 MockGlassesSession 以便无 SDK/无真机开发与测试。
import Foundation

// MARK: - 状态

public enum GlassesSessionState: Sendable, Equatable {
    case idle, starting, started, paused, stopping, stopped
}

public enum DisplayState: Sendable, Equatable {
    case stopped, starting, started, stopping
}

public enum CameraStreamState: Sendable, Equatable {
    case stopped, waitingForDevice, starting, streaming, paused, stopping
}

public enum ThermalLevel: Sendable, Equatable, Comparable {
    case normal, warm, hot, critical
}

public enum GlassesFault: Sendable, Equatable {
    case bluetoothLost
    case thermal(ThermalLevel)
    case batteryCritical
    case systemInterrupted   // 来电等
    case capabilityDenied
    case datAppUpdateRequired
}

// MARK: - 输入

public enum CaptouchGesture: Sendable, Equatable {
    case tap        // 单指点按（onClick 抽象）
    case backOnRoot // L0 上的双指返回（会话结束语义）
}

// MARK: - 相机

public struct CameraPreset: Sendable, Equatable {
    public enum Quality: String, Sendable, CaseIterable { case high, medium, low }
    public var quality: Quality
    public var frameRate: Int   // 2/7/15/24/30

    public init(quality: Quality, frameRate: Int) {
        self.quality = quality
        self.frameRate = frameRate
    }

    /// DAT 规格：high 720×1280 / medium 504×896 / low 360×640
    public var pixelSize: (width: Int, height: Int) {
        switch quality {
        case .high: return (720, 1280)
        case .medium: return (504, 896)
        case .low: return (360, 640)
        }
    }

    public static let `default` = CameraPreset(quality: .medium, frameRate: 24)
}

/// 相机帧的最小抽象（真实实现包 CMSampleBuffer；纯逻辑层只需时序与序号）
public struct CameraFramePacket: Sendable {
    public var sequence: UInt64
    public var timestamp: Date
    /// 不透明载荷句柄（真实层为 CMSampleBuffer 的包装；Mock 层可为空）
    public var payload: (any Sendable)?

    public init(sequence: UInt64, timestamp: Date, payload: (any Sendable)? = nil) {
        self.sequence = sequence
        self.timestamp = timestamp
        self.payload = payload
    }
}

// MARK: - 会话抽象（真实 DAT 与 Mock 共同实现）

public protocol GlassesSessionProviding: Sendable {
    var sessionStates: AsyncStream<GlassesSessionState> { get }
    var displayStates: AsyncStream<DisplayState> { get }
    var cameraStates: AsyncStream<CameraStreamState> { get }
    var thermal: AsyncStream<ThermalLevel> { get }
    var faults: AsyncStream<GlassesFault> { get }
    var captouch: AsyncStream<CaptouchGesture> { get }
    var cameraFrames: AsyncStream<CameraFramePacket> { get }

    func start() async throws
    func stop() async
    func attachCamera(preset: CameraPreset) async throws
    func detachCamera() async
    func attachDisplay() async throws
    func detachDisplay() async
    /// 发送序列化后的布局负载（GlassRenderer 产出）；整屏替换语义。
    func sendDisplayPayload(_ payload: DisplayPayload) async throws
    func clearDisplay() async throws
}

/// 布局负载：GlassRenderer 序列化产物（与 DAT FlexBox 树一一对应的中间表示）
public struct DisplayPayload: Sendable, Equatable {
    /// 稳定序列化（快照测试与幂等去重依据）
    public var canonicalJSON: String
    public init(canonicalJSON: String) { self.canonicalJSON = canonicalJSON }
}
