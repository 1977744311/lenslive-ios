// 多订阅者事件广播（AudioHub 内部工具；与 StreamEngine 同构，
// 两个 target 零依赖故各自持有一份，不做跨模块共享）。
import Foundation

final class AsyncBroadcast<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]

    init() {}

    /// 新建一条订阅流；订阅时刻之后 yield 的元素都会送达（无回放）。
    func stream() -> AsyncStream<Element> {
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

    func yield(_ element: Element) {
        lock.lock()
        let targets = Array(continuations.values)
        lock.unlock()
        for continuation in targets {
            continuation.yield(element)
        }
    }

    func finish() {
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
