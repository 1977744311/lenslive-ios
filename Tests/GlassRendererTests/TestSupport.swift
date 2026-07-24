// 测试基础设施：虚拟时钟（实现 DanmakuCore.Clock_）+ 流收集器 + GlassNode 树遍历辅助。
import Foundation
import GlassesKit
import GlassRenderer
import DanmakuCore

/// 虚拟时钟：sleep 挂起直到 advance 越过 deadline；支持任务取消。
final class VirtualClock: Clock_, @unchecked Sendable {

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

    func waitForSleepers(atLeast n: Int, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if sleeperCount >= n { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

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

/// 轮询任意异步条件直至为真或超时
func eventually(timeout: TimeInterval = 2, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return await condition()
}

// MARK: - GlassNode 树遍历

/// 深度优先收集全部文本节点
func collectTexts(_ node: GlassNode) -> [(text: String, style: GlassTextStyle, color: GlassTextColor)] {
    switch node {
    case let .flexBox(_, children):
        return children.flatMap(collectTexts)
    case let .text(text, style, color):
        return [(text, style, color)]
    default:
        return []
    }
}

/// 深度优先收集全部按钮
func collectButtons(_ node: GlassNode) -> [(label: String, style: GlassButtonStyle, actionID: String)] {
    switch node {
    case let .flexBox(_, children):
        return children.flatMap(collectButtons)
    case let .button(label, style, actionID):
        return [(label, style, actionID)]
    default:
        return []
    }
}

/// 深度优先收集全部图标
func collectIcons(_ node: GlassNode) -> [GlassIconName] {
    switch node {
    case let .flexBox(_, children):
        return children.flatMap(collectIcons)
    case let .icon(name):
        return [name]
    default:
        return []
    }
}

// MARK: - 事件工厂

func chatEvent(id: String, user: String, text: String, question: Bool = false) -> DanmakuEvent {
    DanmakuEvent(id: id, platform: .bilibili, kind: .chat, user: user, text: text,
                 timestamp: Date(timeIntervalSince1970: 0), isQuestion: question)
}

func superChatEvent(id: String, user: String, text: String, value: Double) -> DanmakuEvent {
    DanmakuEvent(id: id, platform: .bilibili, kind: .superChat, user: user, text: text,
                 value: value, timestamp: Date(timeIntervalSince1970: 0))
}
