// op=5 业务消息 JSON → DanmakuEvent 统一事件模型映射（纯函数）。
// 未知 cmd / 解析失败一律返回 nil，不抛错、不中断连接。
import Foundation
import CryptoKit

public enum BiliMessageMapper {
    /// - Parameter receivedAt: payload 无 timestamp 时的兜底事件时间（连接器传 clock.now）。
    public static func map(messageBody: Data, receivedAt: Date = Date()) -> DanmakuEvent? {
        struct Envelope: Decodable {
            let cmd: String
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: messageBody) else {
            return nil
        }
        switch envelope.cmd {
        case "LIVE_OPEN_PLATFORM_DM":
            return mapDM(messageBody, receivedAt: receivedAt)
        case "LIVE_OPEN_PLATFORM_SEND_GIFT":
            return mapGift(messageBody, receivedAt: receivedAt)
        case "LIVE_OPEN_PLATFORM_SUPER_CHAT":
            return mapSuperChat(messageBody, receivedAt: receivedAt)
        case "LIVE_OPEN_PLATFORM_GUARD":
            return mapGuard(messageBody, receivedAt: receivedAt)
        case "LIVE_OPEN_PLATFORM_LIKE":
            return mapLike(messageBody, receivedAt: receivedAt)
        case "LIVE_OPEN_PLATFORM_ENTER_ROOM":
            return mapEnterRoom(messageBody, receivedAt: receivedAt)
        default:
            return nil
        }
    }

    // MARK: - 各 cmd 映射

    private static func mapDM(_ body: Data, receivedAt: Date) -> DanmakuEvent? {
        struct DMData: Decodable {
            let uname: String?
            let msg: String?
            let msg_id: String?
            let timestamp: Double?
        }
        guard let data = decodeData(DMData.self, from: body) else { return nil }
        return DanmakuEvent(
            id: resolveID(data.msg_id, body: body),
            platform: .bilibili,
            kind: .chat,
            user: data.uname ?? "",
            text: data.msg ?? "",
            timestamp: eventDate(data.timestamp, fallback: receivedAt)
        )
    }

    private static func mapGift(_ body: Data, receivedAt: Date) -> DanmakuEvent? {
        struct GiftData: Decodable {
            let uname: String?
            let gift_name: String?
            let gift_num: Int?
            let price: Int64?
            let paid: Bool?
            let msg_id: String?
            let timestamp: Double?
        }
        guard let data = decodeData(GiftData.self, from: body) else { return nil }
        let count = max(data.gift_num ?? 1, 1)
        // price 单位为分；事件金额取总额（单价 × 数量）转元。免费礼物（paid != true）无金额语义。
        var value: Double?
        if data.paid == true, let price = data.price {
            value = Double(price * Int64(count)) / 100.0
        }
        return DanmakuEvent(
            id: resolveID(data.msg_id, body: body),
            platform: .bilibili,
            kind: .gift,
            user: data.uname ?? "",
            text: "\(data.gift_name ?? "礼物") ×\(count)",
            value: value,
            timestamp: eventDate(data.timestamp, fallback: receivedAt)
        )
    }

    private static func mapSuperChat(_ body: Data, receivedAt: Date) -> DanmakuEvent? {
        struct SuperChatData: Decodable {
            let uname: String?
            let message: String?
            let rmb: Double?
            let msg_id: String?
            let timestamp: Double?
        }
        guard let data = decodeData(SuperChatData.self, from: body) else { return nil }
        return DanmakuEvent(
            id: resolveID(data.msg_id, body: body),
            platform: .bilibili,
            kind: .superChat,
            user: data.uname ?? "",
            text: data.message ?? "",
            value: data.rmb,
            timestamp: eventDate(data.timestamp, fallback: receivedAt)
        )
    }

    private static func mapGuard(_ body: Data, receivedAt: Date) -> DanmakuEvent? {
        struct GuardData: Decodable {
            struct UserInfo: Decodable {
                let uname: String?
            }
            let user_info: UserInfo?
            let guard_level: Int?
            let guard_num: Int?
            let guard_unit: String?
            let msg_id: String?
            let timestamp: Double?
        }
        guard let data = decodeData(GuardData.self, from: body) else { return nil }
        let title: String = switch data.guard_level {
        case 1: "总督"
        case 2: "提督"
        case 3: "舰长"
        default: "大航海"
        }
        var text = "开通\(title)"
        if let num = data.guard_num, num > 0 {
            text += " ×\(num)\(data.guard_unit ?? "")"
        }
        return DanmakuEvent(
            id: resolveID(data.msg_id, body: body),
            platform: .bilibili,
            kind: .member,
            user: data.user_info?.uname ?? "",
            text: text,
            timestamp: eventDate(data.timestamp, fallback: receivedAt)
        )
    }

    private static func mapLike(_ body: Data, receivedAt: Date) -> DanmakuEvent? {
        struct LikeData: Decodable {
            let uname: String?
            let like_text: String?
            let msg_id: String?
            let timestamp: Double?
        }
        guard let data = decodeData(LikeData.self, from: body) else { return nil }
        return DanmakuEvent(
            id: resolveID(data.msg_id, body: body),
            platform: .bilibili,
            kind: .like,
            user: data.uname ?? "",
            text: data.like_text ?? "为主播点赞了",
            timestamp: eventDate(data.timestamp, fallback: receivedAt)
        )
    }

    private static func mapEnterRoom(_ body: Data, receivedAt: Date) -> DanmakuEvent? {
        struct EnterData: Decodable {
            let uname: String?
            let msg_id: String?
            let timestamp: Double?
        }
        guard let data = decodeData(EnterData.self, from: body) else { return nil }
        return DanmakuEvent(
            id: resolveID(data.msg_id, body: body),
            platform: .bilibili,
            kind: .enter,
            user: data.uname ?? "",
            text: "进入直播间",
            timestamp: eventDate(data.timestamp, fallback: receivedAt)
        )
    }

    // MARK: - 工具

    private static func decodeData<D: Decodable>(_ type: D.Type, from body: Data) -> D? {
        (try? JSONDecoder().decode(BiliMessagePayload<D>.self, from: body))?.data
    }

    private static func resolveID(_ msgID: String?, body: Data) -> String {
        if let msgID, !msgID.isEmpty { return msgID }
        return stableID(for: body)
    }

    /// msg_id 缺失时对原始报文取 SHA256 前缀：同一报文重放得到同一 id，供聚合器去重。
    private static func stableID(for body: Data) -> String {
        let digest = SHA256.hash(data: body)
        return "bili-" + String(digest.hexEncodedString().prefix(16))
    }

    private static func eventDate(_ timestamp: Double?, fallback: Date) -> Date {
        guard let timestamp, timestamp > 0 else { return fallback }
        return Date(timeIntervalSince1970: timestamp)
    }
}

private struct BiliMessagePayload<T: Decodable>: Decodable {
    let data: T
}
