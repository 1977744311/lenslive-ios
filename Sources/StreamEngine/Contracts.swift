// StreamEngine 契约 —— RTMP 推流管线抽象。
// 真实 HaishinKit 适配器位于 App/Adapters/Streaming/（canImport(HaishinKit) 守护）。
import Foundation

// MARK: - 推流目标

public struct RTMPTarget: Sendable, Equatable, Codable, Identifiable {
    public enum Preset: String, Sendable, Codable, CaseIterable {
        case bilibiliDirect      // B 站直推（≥5000 粉）
        case bilibiliLiveHime    // B 站直播姬本地中转
        case twitch
        case youtube
        case custom              // 抖音等：PC 直播伴侣临时码
    }
    public var id: UUID
    public var preset: Preset
    public var name: String
    public var serverURL: String   // rtmp://...
    /// 串流密钥仅存 Keychain；此处只保存 Keychain 引用键
    public var streamKeyRef: String

    public init(id: UUID = UUID(), preset: Preset, name: String,
                serverURL: String, streamKeyRef: String) {
        self.id = id
        self.preset = preset
        self.name = name
        self.serverURL = serverURL
        self.streamKeyRef = streamKeyRef
    }
}

public enum RTMPTargetValidationError: Error, Sendable, Equatable {
    case invalidScheme      // 非 rtmp:// 或 rtmps://
    case emptyHost
    case emptyStreamKey
}

// MARK: - 管线状态与统计

public enum StreamPipelineState: Sendable, Equatable {
    case idle
    case connecting
    case streaming
    case reconnecting(attempt: Int)
    case stopped
    case failed(reason: String)
}

public struct StreamStats: Sendable, Equatable {
    public var bitrateMbps: Double
    public var fps: Double
    public var droppedFrameRatio: Double   // 0...1
    public var networkGood: Bool

    public init(bitrateMbps: Double, fps: Double, droppedFrameRatio: Double, networkGood: Bool) {
        self.bitrateMbps = bitrateMbps
        self.fps = fps
        self.droppedFrameRatio = droppedFrameRatio
        self.networkGood = networkGood
    }
}

// MARK: - 退避策略（重推 ≤5 次）

public struct BackoffPolicy: Sendable, Equatable {
    public var maxAttempts: Int
    public var baseDelay: TimeInterval
    public var multiplier: Double
    public var maxDelay: TimeInterval

    public init(maxAttempts: Int = 5, baseDelay: TimeInterval = 1,
                multiplier: Double = 2, maxDelay: TimeInterval = 30) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.multiplier = multiplier
        self.maxDelay = maxDelay
    }

    /// attempt 从 1 开始；超出 maxAttempts 返回 nil（放弃）
    public func delay(forAttempt attempt: Int) -> TimeInterval? {
        guard attempt >= 1, attempt <= maxAttempts else { return nil }
        let d = baseDelay * pow(multiplier, Double(attempt - 1))
        return min(d, maxDelay)
    }
}

// MARK: - 管线协议（真实实现：HaishinKitPipelineAdapter；测试实现：MockPipeline）

public protocol StreamPipelining: Sendable {
    var states: AsyncStream<StreamPipelineState> { get }
    var stats: AsyncStream<StreamStats> { get }
    func start(target: RTMPTarget, streamKey: String) async throws
    func stop() async
    /// 由 GlassesKit 相机帧驱动；真实层透传 CMSampleBuffer
    func appendVideoPayload(_ payload: any Sendable, timestampSeconds: Double) async
}
