// 时钟注入点：重连退避的等待经由此协议，单测用虚拟时钟即时返回并记录请求的时长。
import Foundation

public protocol StreamClock: Sendable {
    /// 挂起指定秒数；任务被取消时必须抛出（stop() 依赖此语义中止退避等待）。
    func sleep(seconds: TimeInterval) async throws
}

public struct SystemStreamClock: StreamClock {
    public init() {}

    public func sleep(seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
