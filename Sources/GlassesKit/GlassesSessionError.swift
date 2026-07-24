// 会话操作统一错误域（契约未定义错误分类，实现层补充）。
// GlassRenderer.DisplayDispatcher 依赖 isDisconnection 区分
// "断连 → 缓存待重挂重发" 与 "其余 → 丢弃本帧"；
// 真实 DAT 适配器负责把 SDK 错误映射进本枚举（App/Adapters/GlassesDAT）。
import Foundation

public enum GlassesSessionError: Error, Sendable, Equatable {
    case notConnected        // 蓝牙断连 / 设备不可达（DAT deviceDisconnected 等）
    case sessionNotStarted   // 会话未 started 就调用能力操作
    case displayNotAttached
    case cameraNotAttached
    case capabilityDenied
    case rendering(String)   // 渲染/负载类失败：丢帧不重发
    case underlying(String)  // 其他未归类 SDK 错误

    /// 断连类错误：负载应缓存，待能力重挂后重发
    public var isDisconnection: Bool {
        switch self {
        case .notConnected, .sessionNotStarted: return true
        default: return false
        }
    }
}
