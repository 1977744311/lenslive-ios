// DanmakuCore 契约 —— 各实现文件围绕本文件展开；修改契约需在集成报告中说明理由。
import Foundation

// MARK: - 统一事件模型（架构文档 §3.2）

public enum DanmakuPlatform: String, Sendable, Codable, CaseIterable {
    case bilibili, twitch, youtube, douyin
}

public enum DanmakuEventKind: String, Sendable, Codable {
    case chat        // 普通弹幕
    case gift        // 礼物
    case superChat   // SC / 醒目留言
    case member      // 舰长 / 大航海 / 会员
    case enter       // 进场
    case like        // 点赞
    case system      // 连接状态等系统消息
}

public struct DanmakuEvent: Sendable, Codable, Equatable, Identifiable {
    public var id: String
    public var platform: DanmakuPlatform
    public var kind: DanmakuEventKind
    public var user: String
    public var text: String
    /// 金额（元），礼物/SC 用；普通弹幕为 nil
    public var value: Double?
    public var timestamp: Date
    /// 聚合器标注：命中提问关键词
    public var isQuestion: Bool

    public init(id: String, platform: DanmakuPlatform, kind: DanmakuEventKind,
                user: String, text: String, value: Double? = nil,
                timestamp: Date, isQuestion: Bool = false) {
        self.id = id
        self.platform = platform
        self.kind = kind
        self.user = user
        self.text = text
        self.value = value
        self.timestamp = timestamp
        self.isQuestion = isQuestion
    }

    /// 高价值：SC / 礼物 / 舰长 / 命中提问
    public var isHighValue: Bool {
        switch kind {
        case .superChat, .gift, .member: return true
        case .chat: return isQuestion
        default: return false
        }
    }
}

// MARK: - Connector 协议

public enum ConnectorState: Sendable, Equatable {
    case idle
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case failed(reason: String)
    case stopped
}

/// 平台弹幕连接器。实现：BiliConnector（M0）；Twitch/YouTube（P1）。
public protocol DanmakuConnector: Sendable {
    var platform: DanmakuPlatform { get }
    /// 连接并持续投递事件；状态变化经 states 流上报。
    func start() async
    func stop() async
    var events: AsyncStream<DanmakuEvent> { get }
    var states: AsyncStream<ConnectorState> { get }
}

// MARK: - 时钟注入（节流/驻留调度的单测基础）

public protocol Clock_: Sendable {
    var now: Date { get }
    func sleep(seconds: TimeInterval) async throws
}

public struct SystemClock: Clock_ {
    public init() {}
    public var now: Date { Date() }
    public func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
