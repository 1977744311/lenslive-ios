// 测试基础设施：虚拟时钟（确定性驱动 sleep）+ 流收集器（带超时轮询断言）。
import Foundation
import GlassesKit

/// 虚拟时钟：sleep 挂起直到 advance 越过 deadline；支持任务取消。
final class VirtualClock: GlassesClocking, @unchecked Sendable {

    private struct Sleeper {
        let id: UUID
        let deadline: Date
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var current: Date
    private var sleepers: [Sleeper] = []
    private var cancelledIDs: Set<UUID> = []

    init(start: Date = Date(timeIntervalSince1970: 0)) {
        current = start
    }

    var now: Date { lock.withLock { current } }

    var sleeperCount: Int { lock.withLock { sleepers.count } }

    func sleep(seconds: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if cancelledIDs.remove(id) != nil {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if seconds <= 0 {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                sleepers.append(Sleeper(id: id, deadline: current.addingTimeInterval(seconds), continuation: continuation))
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            if let index = sleepers.firstIndex(where: { $0.id == id }) {
                let sleeper = sleepers.remove(at: index)
                lock.unlock()
                sleeper.continuation.resume(throwing: CancellationError())
            } else {
                cancelledIDs.insert(id)
                lock.unlock()
            }
        }
    }

    /// 推进虚拟时间并按 deadline 顺序唤醒到期 sleeper
    func advance(by seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        var due: [Sleeper] = []
        sleepers.removeAll { sleeper in
            guard sleeper.deadline <= current else { return false }
            due.append(sleeper)
            return true
        }
        due.sort { $0.deadline < $1.deadline }
        lock.unlock()
        for sleeper in due { sleeper.continuation.resume() }
    }

    /// 轮询等待至少 n 个挂起 sleeper（消除跨 actor 调度竞态）
    func waitForSleepers(atLeast n: Int, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if sleeperCount >= n { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    /// 轮询等待所有 sleeper 消失（如取消节拍器后确认已停）
    func waitForSleepersDrained(timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if sleeperCount == 0 { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

/// 后台持续收集 AsyncStream 元素，测试用轮询谓词断言。
final class StreamCollector<Element: Sendable>: @unchecked Sendable {

    private let lock = NSLock()
    private var storage: [Element] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<Element>) {
        task = Task { [weak self] in
            for await value in stream {
                guard let self else { return }
                self.lock.withLock { self.storage.append(value) }
            }
        }
    }

    deinit { task?.cancel() }

    func snapshot() -> [Element] { lock.withLock { storage } }

    var count: Int { lock.withLock { storage.count } }

    /// 轮询直到谓词满足或超时；返回最终判定
    @discardableResult
    func waitFor(timeout: TimeInterval = 2, _ predicate: ([Element]) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(snapshot()) { return true }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return predicate(snapshot())
    }

    func cancel() { task?.cancel() }
}

/// 轮询任意异步条件（如 actor 属性）直至为真或超时
func eventually(timeout: TimeInterval = 2, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return await condition()
}
