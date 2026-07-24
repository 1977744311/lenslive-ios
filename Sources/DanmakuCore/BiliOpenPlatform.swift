// B 站直播开放平台 HTTP 签名与会话管理（start / end / heartbeat）。
// 纯逻辑：HTTP 传输、时间戳、nonce 全部可注入，签名函数可对固定输入复算。
import Foundation
import CryptoKit

// MARK: - 凭据（外部注入，绝不硬编码）

public struct BiliCredentials: Sendable, Equatable {
    public var appID: Int64
    public var accessKey: String
    public var accessSecret: String
    /// 主播身份码（开放平台个人主播接入凭证）
    public var code: String

    public init(appID: Int64, accessKey: String, accessSecret: String, code: String) {
        self.appID = appID
        self.accessKey = accessKey
        self.accessSecret = accessSecret
        self.code = code
    }
}

// MARK: - HTTP 抽象

public struct BiliHTTPResponse: Sendable, Equatable {
    public var statusCode: Int
    public var body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }
}

public protocol BiliHTTPClient: Sendable {
    func post(url: URL, headers: [String: String], body: Data) async throws -> BiliHTTPResponse
}

public struct URLSessionBiliHTTPClient: BiliHTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func post(url: URL, headers: [String: String], body: Data) async throws -> BiliHTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return BiliHTTPResponse(statusCode: http.statusCode, body: data)
    }
}

// MARK: - 请求签名（开放平台标准：header 串字典序拼接 → HMAC-SHA256）

public enum BiliSigner {
    public static func md5Hex(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).hexEncodedString()
    }

    public static func hmacSHA256Hex(message: String, secret: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: SymmetricKey(data: Data(secret.utf8))
        )
        return mac.hexEncodedString()
    }

    /// 待签名串：6 个 x-bili-* 头按 key 字典序以 "key:value" 换行拼接（无末尾换行）。
    public static func signatureBaseString(accessKey: String,
                                           contentMD5: String,
                                           nonce: String,
                                           timestamp: Int64) -> String {
        let fields = [
            "x-bili-accesskeyid": accessKey,
            "x-bili-content-md5": contentMD5,
            "x-bili-signature-method": "HMAC-SHA256",
            "x-bili-signature-nonce": nonce,
            "x-bili-signature-version": "1.0",
            "x-bili-timestamp": String(timestamp),
        ]
        return fields
            .sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value)" }
            .joined(separator: "\n")
    }

    /// 完整请求头：6 个签名头 + Authorization(HMAC-SHA256 hex) + Content-Type/Accept。
    public static func signedHeaders(body: Data,
                                     accessKey: String,
                                     accessSecret: String,
                                     timestamp: Int64,
                                     nonce: String) -> [String: String] {
        let contentMD5 = md5Hex(body)
        let baseString = signatureBaseString(
            accessKey: accessKey, contentMD5: contentMD5, nonce: nonce, timestamp: timestamp
        )
        return [
            "x-bili-accesskeyid": accessKey,
            "x-bili-content-md5": contentMD5,
            "x-bili-signature-method": "HMAC-SHA256",
            "x-bili-signature-nonce": nonce,
            "x-bili-signature-version": "1.0",
            "x-bili-timestamp": String(timestamp),
            "Authorization": hmacSHA256Hex(message: baseString, secret: accessSecret),
            "Content-Type": "application/json",
            "Accept": "application/json",
        ]
    }
}

// MARK: - 开放平台会话客户端

/// start 响应中弹幕长连所需的会话信息。
public struct BiliStartSession: Sendable, Equatable {
    public var gameID: String
    public var wssLinks: [String]
    public var authBody: String

    public init(gameID: String, wssLinks: [String], authBody: String) {
        self.gameID = gameID
        self.wssLinks = wssLinks
        self.authBody = authBody
    }
}

public enum BiliOpenPlatformError: Error, Equatable, Sendable {
    case httpStatus(Int)
    case apiCode(Int, message: String)
    case malformedResponse(String)
}

public struct BiliOpenPlatformClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://live-open.biliapi.com")!

    private let credentials: BiliCredentials
    private let http: any BiliHTTPClient
    private let baseURL: URL
    private let now: @Sendable () -> Date
    private let makeNonce: @Sendable () -> String

    public init(credentials: BiliCredentials,
                http: any BiliHTTPClient = URLSessionBiliHTTPClient(),
                baseURL: URL = BiliOpenPlatformClient.defaultBaseURL,
                now: @escaping @Sendable () -> Date = { Date() },
                makeNonce: @escaping @Sendable () -> String = { UUID().uuidString }) {
        self.credentials = credentials
        self.http = http
        self.baseURL = baseURL
        self.now = now
        self.makeNonce = makeNonce
    }

    /// POST /v2/app/start：换取弹幕 wss 地址、auth_body 与 game_id。
    public func start() async throws -> BiliStartSession {
        struct Request: Encodable, Sendable {
            let app_id: Int64
            let code: String
        }
        struct GameInfo: Decodable {
            let game_id: String
        }
        struct WebsocketInfo: Decodable {
            let auth_body: String
            let wss_link: [String]
        }
        struct StartData: Decodable {
            let game_info: GameInfo
            let websocket_info: WebsocketInfo
        }
        struct StartEnvelope: Decodable {
            let data: StartData?
        }

        let raw = try await post(path: "v2/app/start",
                                 payload: Request(app_id: credentials.appID, code: credentials.code))
        let data: StartData
        do {
            guard let decoded = try JSONDecoder().decode(StartEnvelope.self, from: raw).data else {
                throw BiliOpenPlatformError.malformedResponse("start 响应缺少 data")
            }
            data = decoded
        } catch let error as BiliOpenPlatformError {
            throw error
        } catch {
            throw BiliOpenPlatformError.malformedResponse("start data 解析失败: \(error)")
        }
        guard !data.websocket_info.wss_link.isEmpty else {
            throw BiliOpenPlatformError.malformedResponse("start 响应 wss_link 为空")
        }
        return BiliStartSession(gameID: data.game_info.game_id,
                                wssLinks: data.websocket_info.wss_link,
                                authBody: data.websocket_info.auth_body)
    }

    /// POST /v2/app/end：关闭会话。
    public func end(gameID: String) async throws {
        struct Request: Encodable, Sendable {
            let app_id: Int64
            let game_id: String
        }
        _ = try await post(path: "v2/app/end",
                           payload: Request(app_id: credentials.appID, game_id: gameID))
    }

    /// POST /v2/app/heartbeat：项目心跳，20s 一次（节奏由调用方驱动）。
    public func heartbeat(gameID: String) async throws {
        struct Request: Encodable, Sendable {
            let game_id: String
        }
        _ = try await post(path: "v2/app/heartbeat", payload: Request(game_id: gameID))
    }

    /// 签名并发送请求；校验 HTTP 状态与业务 code 后返回原始响应体。
    private func post(path: String, payload: some Encodable) async throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(payload)
        let headers = BiliSigner.signedHeaders(
            body: body,
            accessKey: credentials.accessKey,
            accessSecret: credentials.accessSecret,
            timestamp: Int64(now().timeIntervalSince1970),
            nonce: makeNonce()
        )
        let response = try await http.post(url: baseURL.appendingPathComponent(path),
                                           headers: headers,
                                           body: body)
        guard response.statusCode == 200 else {
            throw BiliOpenPlatformError.httpStatus(response.statusCode)
        }
        let envelope: CodeEnvelope
        do {
            envelope = try JSONDecoder().decode(CodeEnvelope.self, from: response.body)
        } catch {
            throw BiliOpenPlatformError.malformedResponse("响应体不是合法 JSON 信封")
        }
        guard envelope.code == 0 else {
            throw BiliOpenPlatformError.apiCode(envelope.code, message: envelope.message ?? "")
        }
        return response.body
    }
}

private struct CodeEnvelope: Decodable {
    let code: Int
    let message: String?
}

// MARK: - 模块内工具

extension Sequence where Element == UInt8 {
    func hexEncodedString() -> String {
        let digits = Array("0123456789abcdef".utf8)
        var output: [UInt8] = []
        for byte in self {
            output.append(digits[Int(byte >> 4)])
            output.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: output, as: UTF8.self)
    }
}
