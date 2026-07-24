// 测试基础设施：虚拟时钟、流录制器、假 HTTP/WS。全部离线、确定性。
import Foundation
import XCTest
import DanmakuCore

// MARK: - 虚拟时钟

/// Clock_ 的确定性实现：sleep 挂起直到测试显式 advance 越过 deadline。
final class TestClock: Clock_, @unchecked Sendable {
    private struct Sleeper {
        let deadline: Date
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var currentTime: Date
    private var sleepers: [UUID: Sleeper] = [:]
    private var preCancelled: Set<UUID> = []
    private var _recordedSleepDurations: [TimeInterval] = []

    init(start: Date = Date(timeIntervalSince1970: 0)) {
        self.currentTime = start
    }

    var now: Date {
        lock.withLock { currentTime }
    }

    var sleeperCount: Int {
        lock.withLock { sleepers.count }
    }

    /// 按注册顺序记录的全部 sleep 请求时长（用于断言退避序列）。
    var recordedSleepDurations: [TimeInterval] {
        lock.withLock { _recordedSleepDurations }
    }

    func sleep(seconds: TimeInterval) async throws {
        lock.withLock { _recordedSleepDurations.append(seconds) }
        guard seconds > 0 else {
            try Task.checkCancellation()
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let cancelledBeforeRegistration: Bool = lock.withLock {
                    if preCancelled.remove(id) != nil { return true }
                    sleepers[id] = Sleeper(
                        deadline: currentTime.addingTimeInterval(seconds),
                        continuation: continuation
                    )
                    return false
                }
                if cancelledBeforeRegistration {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let continuation: CheckedContinuation<Void, Error>? = lock.withLock {
                if let sleeper = sleepers.removeValue(forKey: id) {
                    return sleeper.continuation
                }
                preCancelled.insert(id)
                return nil
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// 推进虚拟时间，按 deadline 先后唤醒到期的 sleeper。
    func advance(by seconds: TimeInterval) {
        let due: [Sleeper] = lock.withLock {
            currentTime = currentTime.addingTimeInterval(seconds)
            let dueEntries = sleepers
                .filter { $0.value.deadline <= currentTime }
                .sorted { $0.value.deadline < $1.value.deadline }
            for entry in dueEntries {
                sleepers.removeValue(forKey: entry.key)
            }
            return dueEntries.map(\.value)
        }
        for sleeper in due {
            sleeper.continuation.resume()
        }
    }

    /// 真实时间内轮询等待至少 n 个 sleeper 注册（被测代码的 sleep 调度是异步的）。
    @discardableResult
    func waitForSleepers(atLeast count: Int, timeout: TimeInterval = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if sleeperCount >= count { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return sleeperCount >= count
    }
}

// MARK: - 流录制器

final class StreamRecorder<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [Element] = []
    private var _finished = false
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<Element>) {
        task = Task { [weak self] in
            for await item in stream {
                self?.record(item)
            }
            self?.markFinished()
        }
    }

    var items: [Element] {
        lock.withLock { _items }
    }

    var finished: Bool {
        lock.withLock { _finished }
    }

    private func record(_ item: Element) {
        lock.withLock { _items.append(item) }
    }

    private func markFinished() {
        lock.withLock { _finished = true }
    }
}

/// 真实时间内轮询等待条件成立（上限 timeout，绿路径毫秒级返回）。
func waitUntil(timeout: TimeInterval = 2, _ condition: @escaping @Sendable () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

/// 同 waitUntil，但条件本身是 async（如需跨 actor 读状态）。
func waitUntilAsync(timeout: TimeInterval = 2,
                    _ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await condition()
}

/// 断言条件在 timeout 内成立（XCTAssertTrue 不接受 async autoclosure，统一走此助手）。
func expectEventually(timeout: TimeInterval = 2,
                      _ message: String = "条件超时未成立",
                      file: StaticString = #filePath,
                      line: UInt = #line,
                      _ condition: @escaping @Sendable () -> Bool) async {
    let satisfied = await waitUntil(timeout: timeout, condition)
    XCTAssertTrue(satisfied, message, file: file, line: line)
}

/// 断言虚拟时钟上至少注册了 count 个 sleeper。
func expectSleepers(_ clock: TestClock,
                    atLeast count: Int,
                    timeout: TimeInterval = 2,
                    file: StaticString = #filePath,
                    line: UInt = #line) async {
    let satisfied = await clock.waitForSleepers(atLeast: count, timeout: timeout)
    XCTAssertTrue(satisfied, "期望至少 \(count) 个 sleeper，实际 \(clock.sleeperCount)", file: file, line: line)
}

// MARK: - 假 HTTP

final class FakeBiliHTTPClient: BiliHTTPClient, @unchecked Sendable {
    struct Request: Sendable {
        let url: URL
        let headers: [String: String]
        let body: Data
    }

    private let lock = NSLock()
    private var _requests: [Request] = []
    private let handler: @Sendable (Request) async throws -> BiliHTTPResponse

    init(handler: @escaping @Sendable (Request) async throws -> BiliHTTPResponse) {
        self.handler = handler
    }

    var requests: [Request] {
        lock.withLock { _requests }
    }

    func requestCount(pathSuffix: String) -> Int {
        requests.filter { $0.url.path.hasSuffix(pathSuffix) }.count
    }

    func post(url: URL, headers: [String: String], body: Data) async throws -> BiliHTTPResponse {
        let request = Request(url: url, headers: headers, body: body)
        lock.withLock { _requests.append(request) }
        return try await handler(request)
    }
}

enum BiliFixtures {
    static func startResponse(gameID: String = "game-1",
                              wssLinks: [String] = ["wss://fake.bili/sub"],
                              authBody: String = "AUTH_BODY") -> BiliHTTPResponse {
        let links = wssLinks.map { "\"\($0)\"" }.joined(separator: ",")
        let json = """
        {"code":0,"message":"0","data":{"game_info":{"game_id":"\(gameID)"},\
        "websocket_info":{"auth_body":"\(authBody)","wss_link":[\(links)]}}}
        """
        return BiliHTTPResponse(statusCode: 200, body: Data(json.utf8))
    }

    static let okResponse = BiliHTTPResponse(
        statusCode: 200,
        body: Data(#"{"code":0,"message":"0","data":{}}"#.utf8)
    )
}

// MARK: - 假 WebSocket

struct FakeSocketClosed: Error {}

final class FakeWebSocketConnection: BiliWebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Data] = []
    private var waiters: [UUID: CheckedContinuation<Data, Error>] = [:]
    private var preCancelled: Set<UUID> = []
    private var terminalError: Error?
    private var _sentFrames: [Data] = []

    /// 每次 send 后回调（用于自动回 op8 等脚本行为）。创建后、交给被测代码前设置。
    var onSend: (@Sendable (FakeWebSocketConnection, Data) -> Void)?

    var sentFrames: [Data] {
        lock.withLock { _sentFrames }
    }

    var sentOperations: [UInt32] {
        var decoder = BiliFrameDecoder()
        return sentFrames.flatMap { (try? decoder.decode($0)) ?? [] }.map(\.operation)
    }

    /// 模拟服务端下发一段字节。
    func push(_ data: Data) {
        let waiter: CheckedContinuation<Data, Error>? = lock.withLock {
            if let first = waiters.first {
                waiters.removeValue(forKey: first.key)
                return first.value
            }
            queue.append(data)
            return nil
        }
        waiter?.resume(returning: data)
    }

    /// 模拟连接断开：唤醒所有等待者并让后续收发都抛错。
    func breakConnection(with error: Error) {
        let pending: [CheckedContinuation<Data, Error>] = lock.withLock {
            terminalError = error
            let all = Array(waiters.values)
            waiters.removeAll()
            return all
        }
        for waiter in pending {
            waiter.resume(throwing: error)
        }
    }

    func send(_ data: Data) async throws {
        let error: Error? = lock.withLock {
            if terminalError == nil {
                _sentFrames.append(data)
            }
            return terminalError
        }
        if let error { throw error }
        onSend?(self, data)
    }

    func receive() async throws -> Data {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                enum Action {
                    case data(Data)
                    case error(Error)
                    case wait
                }
                let action: Action = lock.withLock {
                    if !queue.isEmpty { return .data(queue.removeFirst()) }
                    if let terminalError { return .error(terminalError) }
                    if preCancelled.remove(id) != nil { return .error(CancellationError()) }
                    waiters[id] = continuation
                    return .wait
                }
                switch action {
                case .data(let data): continuation.resume(returning: data)
                case .error(let error): continuation.resume(throwing: error)
                case .wait: break
                }
            }
        } onCancel: {
            let continuation: CheckedContinuation<Data, Error>? = lock.withLock {
                if let waiter = waiters.removeValue(forKey: id) { return waiter }
                preCancelled.insert(id)
                return nil
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func close() async {
        breakConnection(with: FakeSocketClosed())
    }
}

final class FakeWebSocketConnector: BiliWebSocketConnector, @unchecked Sendable {
    private let lock = NSLock()
    private var _connections: [FakeWebSocketConnection] = []
    private var _openedURLs: [URL] = []

    /// true 时收到 auth 帧自动回 op8 {"code":0}。
    var autoAuthReply = true
    /// 设置后 open 直接抛错（模拟连不上）。
    var openError: Error?

    var connections: [FakeWebSocketConnection] {
        lock.withLock { _connections }
    }

    var openedURLs: [URL] {
        lock.withLock { _openedURLs }
    }

    func open(url: URL) async throws -> any BiliWebSocketConnection {
        if let error = lock.withLock({ openError }) { throw error }
        let connection = FakeWebSocketConnection()
        if autoAuthReply {
            connection.onSend = { conn, data in
                var decoder = BiliFrameDecoder()
                guard let frames = try? decoder.decode(data) else { return }
                if frames.contains(where: { $0.op == .auth }) {
                    conn.push(BiliWireProtocol.encode(op: .authReply, body: Data(#"{"code":0}"#.utf8)))
                }
            }
        }
        lock.withLock {
            _connections.append(connection)
            _openedURLs.append(url)
        }
        return connection
    }
}

// MARK: - 事件工厂

func makeEvent(id: String,
               kind: DanmakuEventKind = .chat,
               user: String = "user",
               text: String = "text",
               value: Double? = nil,
               isQuestion: Bool = false) -> DanmakuEvent {
    DanmakuEvent(id: id, platform: .bilibili, kind: kind, user: user, text: text,
                 value: value, timestamp: Date(timeIntervalSince1970: 1_753_000_000),
                 isQuestion: isQuestion)
}
