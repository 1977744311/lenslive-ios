// 时钟注入点：HFP 2s 稳定窗口的等待经由此协议，单测用虚拟时钟即时返回并记录时长。
import Foundation

public protocol AudioClock: Sendable {
    /// 挂起指定秒数；任务被取消时必须抛出。
    func sleep(seconds: TimeInterval) async throws
}

public struct SystemAudioClock: AudioClock {
    public init() {}

    public func sleep(seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
