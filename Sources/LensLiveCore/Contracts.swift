// LensLiveCore 契约 —— SessionCoordinator 总状态机（架构文档 §4）。
// 语义要点：上行推流与下行弹幕独立降级——弹幕挂了不断播、推流挂了弹幕还在。
import Foundation
import DanmakuCore
import GlassesKit
import GlassRenderer
import StreamEngine
import AudioHub

// MARK: - 总状态

public enum LiveSessionPhase: Sendable, Equatable {
    case idle
    case preparing
    case live
    case degraded(Set<Subsystem>)   // 部分子系统失效但直播未断
    case interrupted                // 系统抢占（来电等）
    case resuming
    case ending
}

public enum Subsystem: String, Sendable, CaseIterable, Codable {
    case glasses    // 蓝牙会话
    case camera     // 相机流
    case display    // 眼镜屏
    case audio      // 音源
    case rtmp       // 推流
    case danmaku    // 弹幕连接
}

/// 就绪位图 → phase 推导规则：
/// - 全就绪 = .live
/// - camera 或 rtmp 失效 = .degraded（含 rtmp）——直播中断但会话保留
/// - 仅 display / danmaku / audio 失效 = .degraded（不影响推流）
/// - glasses 失效 = .degraded（等待重连），持续超时后由上层决定 ending
public struct ReadinessBitmap: Sendable, Equatable {
    public var ready: Set<Subsystem>
    public init(ready: Set<Subsystem> = []) { self.ready = ready }

    public func phase(whenTargetIs target: Set<Subsystem>) -> LiveSessionPhase {
        if ready.isSuperset(of: target) { return .live }
        let missing = target.subtracting(ready)
        return .degraded(missing)
    }
}

// MARK: - 用户可见事件（控制台横幅/通知）

public enum CoordinatorNotice: Sendable, Equatable {
    case rtmpReconnecting(attempt: Int)
    case rtmpGaveUp
    case bluetoothLost
    case bluetoothRecovered
    case danmakuDisconnected
    case danmakuRecovered
    case thermalWarning(ThermalLevel, degradedTo: CameraPreset?)
    case batteryCritical
    case interruptedBySystem
    case resumed
    case audioFallback(from: AudioSource, to: AudioSource)
}
