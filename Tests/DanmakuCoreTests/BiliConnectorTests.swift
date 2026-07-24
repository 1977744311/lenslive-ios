import XCTest
import DanmakuCore

final class BiliConnectorTests: XCTestCase {
    private func makeAPI(http: FakeBiliHTTPClient) -> BiliOpenPlatformClient {
        BiliOpenPlatformClient(
            credentials: BiliCredentials(appID: 123, accessKey: "ak", accessSecret: "sk", code: "CODE1"),
            http: http,
            now: { Date(timeIntervalSince1970: 1_753_000_000) },
            makeNonce: { "nonce" }
        )
    }

    private func makeHappyHTTP() -> FakeBiliHTTPClient {
        FakeBiliHTTPClient { request in
            if request.url.path.hasSuffix("/app/start") {
                return BiliFixtures.startResponse()
            }
            return BiliFixtures.okResponse
        }
    }

    func testHappyPathAuthEventsAndStop() async throws {
        let http = makeHappyHTTP()
        let ws = FakeWebSocketConnector()
        let clock = TestClock()
        let connector = BiliConnector(api: makeAPI(http: http), webSockets: ws, clock: clock)
        let states = StreamRecorder(connector.states)
        let events = StreamRecorder(connector.events)

        await connector.start()

        await expectEventually { states.items.contains(.connected) }
        XCTAssertEqual(states.items.first, .connecting)
        XCTAssertEqual(ws.openedURLs.map(\.absoluteString), ["wss://fake.bili/sub"])

        // 首帧必须是 op7，body 为 auth_body 原文
        let connection = try XCTUnwrap(ws.connections.first)
        var decoder = BiliFrameDecoder()
        let authFrames = try decoder.decode(try XCTUnwrap(connection.sentFrames.first))
        XCTAssertEqual(authFrames.count, 1)
        XCTAssertEqual(authFrames[0].op, .auth)
        XCTAssertEqual(authFrames[0].body, Data("AUTH_BODY".utf8))

        // 推一条 op5 DM，应映射为事件
        let dm = """
        {"cmd":"LIVE_OPEN_PLATFORM_DM","data":{"uname":"小明","msg":"你好","msg_id":"dm-1",\
        "timestamp":1753350000}}
        """
        connection.push(BiliWireProtocol.encode(op: .message, body: Data(dm.utf8), sequence: 9))
        await expectEventually { events.items.count == 1 }
        XCTAssertEqual(events.items[0].id, "dm-1")
        XCTAssertEqual(events.items[0].kind, .chat)
        XCTAssertEqual(events.items[0].user, "小明")

        // 心跳回应帧不产生事件
        connection.push(BiliWireProtocol.encode(op: .heartbeatReply, sequence: 10))

        await connector.stop()

        await expectEventually { states.items.last == .stopped }
        XCTAssertEqual(http.requestCount(pathSuffix: "/app/end"), 1)
        await expectEventually { states.finished && events.finished }
        XCTAssertEqual(events.items.count, 1)
    }

    func testDualHeartbeatsDrivenByInjectedClock() async throws {
        let http = makeHappyHTTP()
        let ws = FakeWebSocketConnector()
        let clock = TestClock()
        let connector = BiliConnector(api: makeAPI(http: http), webSockets: ws, clock: clock)
        let states = StreamRecorder(connector.states)

        await connector.start()
        await expectEventually { states.items.contains(.connected) }

        // 连接后两路心跳循环各注册一个 sleeper（20s HTTP / 30s WS）
        await expectSleepers(clock, atLeast: 2)
        XCTAssertEqual(clock.recordedSleepDurations.sorted(), [20, 30])

        // t=20：HTTP app heartbeat
        clock.advance(by: 20)
        await expectEventually { [http] in http.requestCount(pathSuffix: "/app/heartbeat") == 1 }
        let heartbeat = try XCTUnwrap(http.requests.last { $0.url.path.hasSuffix("/app/heartbeat") })
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: heartbeat.body) as? [String: AnyHashable],
            ["game_id": "game-1"]
        )

        // t=30：WS op2 心跳（空 body）
        await expectSleepers(clock, atLeast: 2)
        clock.advance(by: 10)
        let connection = try XCTUnwrap(ws.connections.first)
        await expectEventually { [connection] in
            connection.sentOperations.contains(BiliFrameOperation.heartbeat.rawValue)
        }

        await connector.stop()
    }

    func testReconnectExhaustionBackoffSequenceThenFailed() async {
        let http = FakeBiliHTTPClient { _ in BiliHTTPResponse(statusCode: 500, body: Data()) }
        let ws = FakeWebSocketConnector()
        let clock = TestClock()
        let connector = BiliConnector(api: makeAPI(http: http), webSockets: ws, clock: clock)
        let states = StreamRecorder(connector.states)

        await connector.start()

        // 5 次退避重连，全部失败
        for _ in 0..<5 {
            await expectSleepers(clock, atLeast: 1)
            clock.advance(by: 30)
        }

        await expectEventually { [states] in
            if case .failed = states.items.last { return true }
            return false
        }
        XCTAssertEqual(clock.recordedSleepDurations, [1, 2, 4, 8, 16], "1s 起倍增")
        XCTAssertEqual(http.requestCount(pathSuffix: "/app/start"), 6, "首连 + 5 次重连")
        XCTAssertEqual(
            Array(states.items.dropLast()),
            [.connecting,
             .reconnecting(attempt: 1), .reconnecting(attempt: 2), .reconnecting(attempt: 3),
             .reconnecting(attempt: 4), .reconnecting(attempt: 5)]
        )
        await expectEventually { states.finished }
    }

    func testReconnectAfterDropRedoesHTTPStartAndResetsAttempts() async throws {
        let http = makeHappyHTTP()
        let ws = FakeWebSocketConnector()
        let clock = TestClock()
        let connector = BiliConnector(api: makeAPI(http: http), webSockets: ws, clock: clock)
        let states = StreamRecorder(connector.states)

        await connector.start()
        await expectEventually { states.items.contains(.connected) }

        // 断线 → 退避 1s → 重新走 HTTP start → 重新 connected
        let first = try XCTUnwrap(ws.connections.first)
        first.breakConnection(with: URLError(.networkConnectionLost))

        await expectEventually { states.items.contains(.reconnecting(attempt: 1)) }
        await expectSleepers(clock, atLeast: 1)
        clock.advance(by: 1)

        await expectEventually { [states] in
            states.items.filter { $0 == .connected }.count == 2
        }
        XCTAssertEqual(http.requestCount(pathSuffix: "/app/start"), 2, "重连必须重新走 HTTP start")
        XCTAssertEqual(ws.connections.count, 2)

        // 第二次断线：attempt 计数已随成功连接归零，仍从 1 开始
        ws.connections[1].breakConnection(with: URLError(.networkConnectionLost))
        await expectEventually { [states] in
            states.items.filter { $0 == .reconnecting(attempt: 1) }.count == 2
        }

        await connector.stop()
    }

    func testAuthRejectedTriggersReconnectFlow() async {
        let http = makeHappyHTTP()
        let ws = FakeWebSocketConnector()
        ws.autoAuthReply = false
        let clock = TestClock()
        let connector = BiliConnector(
            api: makeAPI(http: http), webSockets: ws, clock: clock,
            configuration: .init(maxReconnectAttempts: 1)
        )
        let states = StreamRecorder(connector.states)

        await connector.start()
        await expectEventually { [ws] in ws.connections.count == 1 }
        ws.connections[0].push(BiliWireProtocol.encode(op: .authReply, body: Data(#"{"code":7003}"#.utf8)))

        await expectEventually { states.items.contains(.reconnecting(attempt: 1)) }
        XCTAssertFalse(states.items.contains(.connected))

        // 唯一一次重试也被拒 → failed，原因带 authRejected
        await expectSleepers(clock, atLeast: 1)
        clock.advance(by: 1)
        await expectEventually { [ws] in ws.connections.count == 2 }
        ws.connections[1].push(BiliWireProtocol.encode(op: .authReply, body: Data(#"{"code":7003}"#.utf8)))

        await expectEventually { [states] in
            if case .failed(let reason) = states.items.last { return reason.contains("authRejected") }
            return false
        }
    }

    func testStopDuringBackoffGoesQuiet() async {
        let http = FakeBiliHTTPClient { _ in BiliHTTPResponse(statusCode: 500, body: Data()) }
        let ws = FakeWebSocketConnector()
        let clock = TestClock()
        let connector = BiliConnector(api: makeAPI(http: http), webSockets: ws, clock: clock)
        let states = StreamRecorder(connector.states)

        await connector.start()
        await expectSleepers(clock, atLeast: 1)

        await connector.stop()

        await expectEventually { states.items.last == .stopped }
        await expectEventually { states.finished }
        // 退避被取消后不再重试
        XCTAssertEqual(http.requestCount(pathSuffix: "/app/start"), 1)
    }
}
