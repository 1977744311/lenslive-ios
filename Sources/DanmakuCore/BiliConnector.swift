// B 站弹幕连接器：DanmakuConnector 实现（actor）。
// 生命周期：HTTP start → WS 连接 → auth(op7) → 等 op8 → connected；
// 双心跳（WS op2 / HTTP app heartbeat）；断线退避重连（重新走 HTTP start）；stop → HTTP end + 优雅关闭。
import Foundation

// MARK: - WebSocket 抽象（注入以便离线测试）

public protocol BiliWebSocketConnection: Sendable {
    func send(_ data: Data) async throws
    /// 返回下一条二进制消息（文本消息按 UTF-8 转 Data）；连接断开时抛错。
    func receive() async throws -> Data
    func close() async
}

public protocol BiliWebSocketConnector: Sendable {
    func open(url: URL) async throws -> any BiliWebSocketConnection
}

public final class URLSessionWebSocketConnection: BiliWebSocketConnection, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    public func send(_ data: Data) async throws {
        try await task.send(.data(data))
    }

    public func receive() async throws -> Data {
        while true {
            switch try await task.receive() {
            case .data(let data):
                return data
            case .string(let text):
                return Data(text.utf8)
            @unknown default:
                continue
            }
        }
    }

    public func close() async {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

public struct URLSessionWebSocketConnector: BiliWebSocketConnector {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func open(url: URL) async throws -> any BiliWebSocketConnection {
        let task = session.webSocketTask(with: url)
        task.resume() // 握手失败在首次 send/receive 时暴露
        return URLSessionWebSocketConnection(task: task)
    }
}

// MARK: - 连接器

public enum BiliConnectorError: Error, Equatable, Sendable {
    case missingWSSLink
    case authRejected(code: Int)
}

public actor BiliConnector: DanmakuConnector {
    public struct Configuration: Sendable {
        public var wsHeartbeatInterval: TimeInterval
        public var httpHeartbeatInterval: TimeInterval
        public var maxReconnectAttempts: Int
        public var reconnectBaseDelay: TimeInterval
        public var reconnectMaxDelay: TimeInterval

        public init(wsHeartbeatInterval: TimeInterval = 30,
                    httpHeartbeatInterval: TimeInterval = 20,
                    maxReconnectAttempts: Int = 5,
                    reconnectBaseDelay: TimeInterval = 1,
                    reconnectMaxDelay: TimeInterval = 30) {
            self.wsHeartbeatInterval = wsHeartbeatInterval
            self.httpHeartbeatInterval = httpHeartbeatInterval
            self.maxReconnectAttempts = maxReconnectAttempts
            self.reconnectBaseDelay = reconnectBaseDelay
            self.reconnectMaxDelay = reconnectMaxDelay
        }
    }

    nonisolated public var platform: DanmakuPlatform { .bilibili }
    nonisolated public let events: AsyncStream<DanmakuEvent>
    nonisolated public let states: AsyncStream<ConnectorState>

    private let eventContinuation: AsyncStream<DanmakuEvent>.Continuation
    private let stateContinuation: AsyncStream<ConnectorState>.Continuation
    private let api: BiliOpenPlatformClient
    private let webSockets: any BiliWebSocketConnector
    private let clock: any Clock_
    private let configuration: Configuration

    private var runTask: Task<Void, Never>?
    private var activeConnection: (any BiliWebSocketConnection)?
    private var activeGameID: String?
    private var currentAttempt = 0
    private var sequence: UInt32 = 0
    private var isStopped = false

    public init(api: BiliOpenPlatformClient,
                webSockets: any BiliWebSocketConnector = URLSessionWebSocketConnector(),
                clock: any Clock_ = SystemClock(),
                configuration: Configuration = Configuration()) {
        self.api = api
        self.webSockets = webSockets
        self.clock = clock
        self.configuration = configuration
        let (eventStream, eventContinuation) = AsyncStream.makeStream(of: DanmakuEvent.self)
        let (stateStream, stateContinuation) = AsyncStream.makeStream(of: ConnectorState.self)
        self.events = eventStream
        self.eventContinuation = eventContinuation
        self.states = stateStream
        self.stateContinuation = stateContinuation
    }

    public init(credentials: BiliCredentials,
                httpClient: any BiliHTTPClient = URLSessionBiliHTTPClient(),
                webSockets: any BiliWebSocketConnector = URLSessionWebSocketConnector(),
                clock: any Clock_ = SystemClock(),
                configuration: Configuration = Configuration()) {
        self.init(api: BiliOpenPlatformClient(credentials: credentials, http: httpClient),
                  webSockets: webSockets,
                  clock: clock,
                  configuration: configuration)
    }

    // MARK: DanmakuConnector

    public func start() async {
        guard !isStopped, runTask == nil else { return }
        yieldState(.connecting)
        runTask = Task { await self.run() }
    }

    public func stop() async {
        guard !isStopped else { return }
        isStopped = true
        runTask?.cancel()
        runTask = nil
        if let connection = activeConnection {
            activeConnection = nil
            await connection.close()
        }
        if let gameID = activeGameID {
            activeGameID = nil
            try? await api.end(gameID: gameID)
        }
        yieldState(.stopped)
        finishStreams()
    }

    // MARK: - 主循环

    private func run() async {
        while !isStopped && !Task.isCancelled {
            do {
                try await connectOnce()
                break // 正常返回只发生在取消/停止时
            } catch {
                if isStopped || Task.isCancelled { break }
                currentAttempt += 1
                if currentAttempt > configuration.maxReconnectAttempts {
                    yieldState(.failed(reason: String(describing: error)))
                    finishStreams()
                    return
                }
                yieldState(.reconnecting(attempt: currentAttempt))
                let delay = min(
                    configuration.reconnectBaseDelay * pow(2.0, Double(currentAttempt - 1)),
                    configuration.reconnectMaxDelay
                )
                do {
                    try await clock.sleep(seconds: delay)
                } catch {
                    break // 退避期间被取消
                }
            }
        }
    }

    /// 单次完整会话：HTTP start → WS → auth → 心跳/读循环，抛错即触发上层重连。
    private func connectOnce() async throws {
        let session = try await api.start()
        guard let link = session.wssLinks.first, let url = URL(string: link) else {
            throw BiliConnectorError.missingWSSLink
        }
        activeGameID = session.gameID
        let connection = try await webSockets.open(url: url)
        activeConnection = connection
        do {
            try await runSession(connection: connection, session: session)
        } catch {
            activeConnection = nil
            await connection.close()
            throw error
        }
        activeConnection = nil
        await connection.close()
    }

    private func runSession(connection: any BiliWebSocketConnection,
                            session: BiliStartSession) async throws {
        sequence += 1
        try await connection.send(
            BiliWireProtocol.encode(op: .auth, body: Data(session.authBody.utf8), sequence: sequence)
        )
        let decoder = try await awaitAuthReply(on: connection)
        currentAttempt = 0
        yieldState(.connected)
        let gameID = session.gameID
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.readLoop(connection: connection, decoder: decoder) }
            group.addTask { try await self.wsHeartbeatLoop(connection: connection) }
            group.addTask { try await self.httpHeartbeatLoop(gameID: gameID) }
            do {
                _ = try await group.next()
            } catch {
                group.cancelAll()
                await connection.close() // 解除 receive 阻塞，保证子任务能收尾
                throw error
            }
            group.cancelAll()
            await connection.close()
        }
    }

    private func awaitAuthReply(on connection: any BiliWebSocketConnection) async throws -> BiliFrameDecoder {
        var decoder = BiliFrameDecoder()
        while true {
            let data = try await connection.receive()
            var sawAuthReply = false
            for frame in try decoder.decode(data) {
                if frame.op == .authReply {
                    try validateAuthReply(frame)
                    sawAuthReply = true
                } else {
                    handleFrame(frame)
                }
            }
            if sawAuthReply { return decoder }
        }
    }

    private func validateAuthReply(_ frame: BiliFrame) throws {
        struct AuthReply: Decodable {
            let code: Int?
        }
        guard !frame.body.isEmpty,
              let reply = try? JSONDecoder().decode(AuthReply.self, from: frame.body) else {
            return // 空 body / 非 JSON 回应按成功处理
        }
        if let code = reply.code, code != 0 {
            throw BiliConnectorError.authRejected(code: code)
        }
    }

    private func readLoop(connection: any BiliWebSocketConnection,
                          decoder: BiliFrameDecoder) async throws {
        var decoder = decoder
        while !Task.isCancelled {
            let data = try await connection.receive()
            for frame in try decoder.decode(data) {
                handleFrame(frame)
            }
        }
    }

    private func wsHeartbeatLoop(connection: any BiliWebSocketConnection) async throws {
        while !Task.isCancelled {
            try await clock.sleep(seconds: configuration.wsHeartbeatInterval)
            sequence += 1
            try await connection.send(BiliWireProtocol.encode(op: .heartbeat, sequence: sequence))
        }
    }

    private func httpHeartbeatLoop(gameID: String) async throws {
        while !Task.isCancelled {
            try await clock.sleep(seconds: configuration.httpHeartbeatInterval)
            try await api.heartbeat(gameID: gameID)
        }
    }

    private func handleFrame(_ frame: BiliFrame) {
        switch frame.op {
        case .message:
            if let event = BiliMessageMapper.map(messageBody: frame.body, receivedAt: clock.now) {
                eventContinuation.yield(event)
            }
        default:
            break // 心跳回应等无事件语义帧
        }
    }

    private func yieldState(_ state: ConnectorState) {
        stateContinuation.yield(state)
    }

    private func finishStreams() {
        eventContinuation.finish()
        stateContinuation.finish()
    }
}
