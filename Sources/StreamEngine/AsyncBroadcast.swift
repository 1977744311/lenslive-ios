// 多订阅者事件广播：AsyncStream 本身只支持单消费者，
// 库内状态机与 App 适配器（HaishinKitPipelineAdapter）都用它实现 states/stats 的
// "每次访问返回一条独立流" 语义，故为 public。
import Foundation

public final class AsyncBroadcast<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]

    public init() {}

    /// 新建一条订阅流；订阅时刻之后 yield 的元素都会送达（无回放）。
    public func stream() -> AsyncStream<Element> {
        AsyncStream { continuation in
            let id = UUID()
            continuation.onTermination = { [weak self] _ in
                self?.remove(id)
            }
            lock.lock()
            continuations[id] = continuation
            lock.unlock()
        }
    }

    public func yield(_ element: Element) {
        lock.lock()
        let targets = Array(continuations.values)
        lock.unlock()
        for continuation in targets {
            continuation.yield(element)
        }
    }

    public func finish() {
        lock.lock()
        let targets = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for continuation in targets {
            continuation.finish()
        }
    }

    private func remove(_ id: UUID) {
        lock.lock()
        continuations.removeValue(forKey: id)
        lock.unlock()
    }
}
