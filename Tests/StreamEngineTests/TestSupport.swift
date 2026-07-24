// StreamEngineTests 公共设施：虚拟时钟、事件收集器、Mock 管线。全部无真实网络/真实等待。
import Foundation
@testable import StreamEngine

/// 虚拟时钟：即时返回，只记录请求的睡眠时长；取消时抛错（与真实时钟语义一致）。
final class TestStreamClock: StreamClock, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TimeInterval] = []

    var sleeps: [TimeInterval] { lock.withLock { recorded } }

    func sleep(seconds: TimeInterval) async throws {
        lock.withLock { recorded.append(seconds) }
        try Task.checkCancellation()
        await Task.yield()
    }
}

/// AsyncStream 事件收集器（后台任务持续消费，测试侧随时取快照）。
final class Recorder<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Element] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<Element>) {
        task = Task { [weak self] in
            for await element in stream {
                guard let self else { return }
                self.lock.withLock { self.items.append(element) }
            }
        }
    }

    var snapshot: [Element] { lock.withLock { items } }

    deinit { task?.cancel() }
}

/// 轮询等待异步条件成立（虚拟时钟下事件到达仍是异步的，用它消除时序抖动）。
func waitUntil(timeoutSeconds: TimeInterval = 2,
               _ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await condition()
}

struct MockPipelineError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// 可编排的 Mock 管线：start 行为按脚本队列依次弹出，队列耗尽后用 fallback。
final class MockPipeline: StreamPipelining, @unchecked Sendable {
    enum StartBehavior {
        /// start 成功并依次上报 connecting → streaming
        case succeed
        /// start 成功但不上报任何状态（模拟连接后悬置）
        case succeedSilently
        /// start 抛错（模拟连接被拒）
        case fail(String)
    }

    private let lock = NSLock()
    private let stateChannel = AsyncBroadcast<StreamPipelineState>()
    private let statsChannel = AsyncBroadcast<StreamStats>()
    private var behaviorQueue: [StartBehavior] = []
    private var fallbackBehavior: StartBehavior = .succeed
    private var recordedStarts: [(target: RTMPTarget, key: String)] = []
    private var recordedStops = 0

    var states: AsyncStream<StreamPipelineState> { stateChannel.stream() }
    var stats: AsyncStream<StreamStats> { statsChannel.stream() }

    var startCalls: [(target: RTMPTarget, key: String)] { lock.withLock { recordedStarts } }
    var stopCount: Int { lock.withLock { recordedStops } }

    func script(_ behaviors: [StartBehavior], fallback: StartBehavior = .succeed) {
        lock.withLock {
            behaviorQueue = behaviors
            fallbackBehavior = fallback
        }
    }

    func start(target: RTMPTarget, streamKey: String) async throws {
        let behavior: StartBehavior = lock.withLock {
            recordedStarts.append((target, streamKey))
            return behaviorQueue.isEmpty ? fallbackBehavior : behaviorQueue.removeFirst()
        }
        switch behavior {
        case .succeed:
            stateChannel.yield(.connecting)
            stateChannel.yield(.streaming)
        case .succeedSilently:
            break
        case .fail(let message):
            throw MockPipelineError(message: message)
        }
    }

    func stop() async {
        lock.withLock { recordedStops += 1 }
        stateChannel.yield(.stopped)
    }

    func appendVideoPayload(_ payload: any Sendable, timestampSeconds: Double) async {}

    /// 注入断流等异步事件
    func emitState(_ state: StreamPipelineState) { stateChannel.yield(state) }
    func emitStats(_ sample: StreamStats) { statsChannel.yield(sample) }
}
