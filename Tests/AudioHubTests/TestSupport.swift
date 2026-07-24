// AudioHubTests 公共设施：虚拟时钟、事件收集器、Mock 端口。无真实音频会话。
import Foundation
@testable import AudioHub

/// 虚拟时钟：即时返回，只记录请求的睡眠时长。
final class TestAudioClock: AudioClock, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TimeInterval] = []

    var sleeps: [TimeInterval] { lock.withLock { recorded } }
    var totalSlept: TimeInterval { lock.withLock { recorded.reduce(0, +) } }

    func sleep(seconds: TimeInterval) async throws {
        lock.withLock { recorded.append(seconds) }
        try Task.checkCancellation()
        await Task.yield()
    }
}

/// AsyncStream 事件收集器。
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

func waitUntil(timeoutSeconds: TimeInterval = 2,
               _ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await condition()
}

struct PortError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// Mock 系统端口：记录调用序列，可注入配置失败与校验结果。
final class MockPorts: AudioPortControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var configureErrors: [AudioSource: PortError] = [:]
    private var verifyAnswers: [AudioSource: Bool] = [:]
    private var recorded: [String] = []

    /// 形如 ["teardown", "configure:glassesHFP", "verify:glassesHFP"]
    var calls: [String] { lock.withLock { recorded } }

    func failConfigure(for source: AudioSource, message: String) {
        lock.withLock { configureErrors[source] = PortError(message: message) }
    }

    func answerVerify(for source: AudioSource, with result: Bool) {
        lock.withLock { verifyAnswers[source] = result }
    }

    func configureRoute(for source: AudioSource) async throws {
        let error: PortError? = lock.withLock {
            recorded.append("configure:\(source.rawValue)")
            return configureErrors[source]
        }
        if let error { throw error }
    }

    func verifyRoute(for source: AudioSource) async -> Bool {
        lock.withLock {
            recorded.append("verify:\(source.rawValue)")
            return verifyAnswers[source, default: true]
        }
    }

    func teardown() async {
        lock.withLock { recorded.append("teardown") }
    }
}
