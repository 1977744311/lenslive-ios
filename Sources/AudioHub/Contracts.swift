// AudioHub 契约 —— 音源三选一与 HFP 顺序约束（官方要求：相机流 start 前 HFP 路由必须稳定）。
import Foundation

public enum AudioSource: String, Sendable, Codable, CaseIterable {
    case iphoneMic   // 默认
    case glassesHFP  // 眼镜麦克风（8kHz 单声道，电话音质）
    case muted
}

public enum AudioRouteState: Sendable, Equatable {
    case inactive
    case configuring
    /// HFP 专用：路由建立后需等待稳定窗口（官方样例 2s）再校验
    case settling(remaining: TimeInterval)
    case active(AudioSource)
    case fallback(from: AudioSource, to: AudioSource, reason: String)
    case failed(reason: String)
}

public protocol AudioRouting: Sendable {
    var states: AsyncStream<AudioRouteState> { get }
    var currentSource: AudioSource { get async }
    /// 切换音源；HFP 失败必须自动回退 iphoneMic 并发出 .fallback 状态。
    /// 返回最终生效的音源。
    @discardableResult
    func activate(_ source: AudioSource) async -> AudioSource
    func deactivate() async
}
