import XCTest
import CryptoKit
import DanmakuCore

final class BiliOpenPlatformTests: XCTestCase {
    private let credentials = BiliCredentials(appID: 123, accessKey: "ak", accessSecret: "secret", code: "CODE1")

    private func makeClient(http: FakeBiliHTTPClient) -> BiliOpenPlatformClient {
        BiliOpenPlatformClient(
            credentials: credentials,
            http: http,
            now: { Date(timeIntervalSince1970: 1_753_000_000) },
            makeNonce: { "nonce-1" }
        )
    }

    // MARK: - 签名

    func testSignedHeadersFieldsCompleteAndSelfConsistent() {
        let body = Data(#"{"app_id":123,"code":"XYZ"}"#.utf8)
        let headers = BiliSigner.signedHeaders(
            body: body, accessKey: "ak", accessSecret: "secret",
            timestamp: 1_753_000_000, nonce: "nonce-1"
        )

        // 六个签名头齐全且值正确
        XCTAssertEqual(headers["x-bili-accesskeyid"], "ak")
        XCTAssertEqual(headers["x-bili-signature-method"], "HMAC-SHA256")
        XCTAssertEqual(headers["x-bili-signature-nonce"], "nonce-1")
        XCTAssertEqual(headers["x-bili-signature-version"], "1.0")
        XCTAssertEqual(headers["x-bili-timestamp"], "1753000000")
        XCTAssertEqual(headers["Content-Type"], "application/json")
        XCTAssertEqual(headers["Accept"], "application/json")

        // content-md5 与 CryptoKit 复算一致
        let expectedMD5 = Insecure.MD5.hash(data: body)
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(headers["x-bili-content-md5"], expectedMD5)

        // 待签名串字典序固定
        let expectedBase = """
        x-bili-accesskeyid:ak
        x-bili-content-md5:\(expectedMD5)
        x-bili-signature-method:HMAC-SHA256
        x-bili-signature-nonce:nonce-1
        x-bili-signature-version:1.0
        x-bili-timestamp:1753000000
        """
        XCTAssertEqual(
            BiliSigner.signatureBaseString(accessKey: "ak", contentMD5: expectedMD5,
                                           nonce: "nonce-1", timestamp: 1_753_000_000),
            expectedBase
        )

        // Authorization 可用 CryptoKit 独立复算
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(expectedBase.utf8),
            using: SymmetricKey(data: Data("secret".utf8))
        )
        let expectedSignature = mac.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(headers["Authorization"], expectedSignature)
    }

    func testSignatureIsDeterministicForFixedInput() {
        let body = Data(#"{"game_id":"g"}"#.utf8)
        let first = BiliSigner.signedHeaders(body: body, accessKey: "ak", accessSecret: "sk",
                                             timestamp: 42, nonce: "n")
        let second = BiliSigner.signedHeaders(body: body, accessKey: "ak", accessSecret: "sk",
                                              timestamp: 42, nonce: "n")
        XCTAssertEqual(first, second)
    }

    func testHMACSHA256KnownVector() {
        // RFC 4231 Test Case 2
        XCTAssertEqual(
            BiliSigner.hmacSHA256Hex(message: "what do ya want for nothing?", secret: "Jefe"),
            "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
        )
    }

    func testEmptyBodyMD5KnownValue() {
        XCTAssertEqual(BiliSigner.md5Hex(Data()), "d41d8cd98f00b204e9800998ecf8427e")
    }

    // MARK: - start / end / heartbeat

    func testStartParsesSessionAndSignsRequest() async throws {
        let http = FakeBiliHTTPClient { _ in
            BiliFixtures.startResponse(gameID: "game-9",
                                       wssLinks: ["wss://a.bili/sub", "wss://b.bili/sub"],
                                       authBody: "AUTH_RAW")
        }
        let client = makeClient(http: http)

        let session = try await client.start()

        XCTAssertEqual(session.gameID, "game-9")
        XCTAssertEqual(session.wssLinks, ["wss://a.bili/sub", "wss://b.bili/sub"])
        XCTAssertEqual(session.authBody, "AUTH_RAW")

        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.url.absoluteString, "https://live-open.biliapi.com/v2/app/start")
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: request.body) as? [String: AnyHashable],
            ["app_id": 123, "code": "CODE1"]
        )
        // 请求带完整签名头，且与对相同 body/时间戳/nonce 的复算一致
        let expected = BiliSigner.signedHeaders(body: request.body, accessKey: "ak",
                                                accessSecret: "secret",
                                                timestamp: 1_753_000_000, nonce: "nonce-1")
        XCTAssertEqual(request.headers, expected)
    }

    func testEndAndHeartbeatBodies() async throws {
        let http = FakeBiliHTTPClient { _ in BiliFixtures.okResponse }
        let client = makeClient(http: http)

        try await client.end(gameID: "game-3")
        try await client.heartbeat(gameID: "game-3")

        XCTAssertEqual(http.requests.count, 2)
        XCTAssertEqual(http.requests[0].url.absoluteString, "https://live-open.biliapi.com/v2/app/end")
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: http.requests[0].body) as? [String: AnyHashable],
            ["app_id": 123, "game_id": "game-3"]
        )
        XCTAssertEqual(http.requests[1].url.absoluteString, "https://live-open.biliapi.com/v2/app/heartbeat")
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: http.requests[1].body) as? [String: AnyHashable],
            ["game_id": "game-3"]
        )
    }

    func testHTTPStatusErrorSurfaces() async {
        let http = FakeBiliHTTPClient { _ in BiliHTTPResponse(statusCode: 500, body: Data()) }
        let client = makeClient(http: http)

        do {
            _ = try await client.start()
            XCTFail("应当抛错")
        } catch {
            XCTAssertEqual(error as? BiliOpenPlatformError, .httpStatus(500))
        }
    }

    func testAPICodeErrorSurfaces() async {
        let http = FakeBiliHTTPClient { _ in
            BiliHTTPResponse(statusCode: 200,
                             body: Data(#"{"code":6002,"message":"身份码错误"}"#.utf8))
        }
        let client = makeClient(http: http)

        do {
            _ = try await client.start()
            XCTFail("应当抛错")
        } catch {
            XCTAssertEqual(error as? BiliOpenPlatformError, .apiCode(6002, message: "身份码错误"))
        }
    }

    func testStartWithEmptyWSSLinkIsMalformed() async {
        let http = FakeBiliHTTPClient { _ in
            BiliFixtures.startResponse(wssLinks: [])
        }
        let client = makeClient(http: http)

        do {
            _ = try await client.start()
            XCTFail("应当抛错")
        } catch let error as BiliOpenPlatformError {
            guard case .malformedResponse = error else {
                return XCTFail("期望 malformedResponse，实际 \(error)")
            }
        } catch {
            XCTFail("期望 BiliOpenPlatformError，实际 \(error)")
        }
    }
}
