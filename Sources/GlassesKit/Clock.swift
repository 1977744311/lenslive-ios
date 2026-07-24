// 时钟注入点 —— GlassesKit 在依赖图上不能引用 DanmakuCore，
// 故自带与 DanmakuCore.Clock_ 同语义的最小时钟抽象；单测注入虚拟时钟。
import Foundation

public protocol GlassesClocking: Sendable {
    var now: Date { get }
    func sleep(seconds: TimeInterval) async throws
}

public struct GlassesSystemClock: GlassesClocking {
    public init() {}
    public var now: Date { Date() }
    public func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}
