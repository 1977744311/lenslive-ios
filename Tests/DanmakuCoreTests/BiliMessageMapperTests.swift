import XCTest
import DanmakuCore

final class BiliMessageMapperTests: XCTestCase {
    private let fallbackDate = Date(timeIntervalSince1970: 9_999)

    func testMapDM() throws {
        let json = """
        {"cmd":"LIVE_OPEN_PLATFORM_DM","data":{"room_id":1,"uid":100,"uname":"小明",\
        "msg":"主播这是多少钱","msg_id":"dm-1","timestamp":1753350000}}
        """
        let event = try XCTUnwrap(BiliMessageMapper.map(messageBody: Data(json.utf8),
                                                        receivedAt: fallbackDate))

        XCTAssertEqual(event.id, "dm-1")
        XCTAssertEqual(event.platform, .bilibili)
        XCTAssertEqual(event.kind, .chat)
        XCTAssertEqual(event.user, "小明")
        XCTAssertEqual(event.text, "主播这是多少钱")
        XCTAssertNil(event.value)
        XCTAssertEqual(event.timestamp, Date(timeIntervalSince1970: 1_753_350_000))
        XCTAssertFalse(event.isQuestion) // 提问识别属于聚合器职责
    }

    func testMapPaidGiftConvertsFenToYuanTotal() throws {
        let json = """
        {"cmd":"LIVE_OPEN_PLATFORM_SEND_GIFT","data":{"uname":"土豪","gift_name":"辣条",\
        "gift_num":5,"price":100,"paid":true,"msg_id":"g-1","timestamp":1753350001}}
        """
        let event = try XCTUnwrap(BiliMessageMapper.map(messageBody: Data(json.utf8),
                                                        receivedAt: fallbackDate))

        XCTAssertEqual(event.kind, .gift)
        XCTAssertEqual(event.user, "土豪")
        XCTAssertEqual(event.text, "辣条 ×5")
        XCTAssertEqual(event.value, 5.0) // 100 分 × 5 = 5 元
        XCTAssertTrue(event.isHighValue)
    }

    func testMapFreeGiftHasNoValue() throws {
        let json = """
        {"cmd":"LIVE_OPEN_PLATFORM_SEND_GIFT","data":{"uname":"白嫖","gift_name":"小心心",\
        "gift_num":1,"price":0,"paid":false,"msg_id":"g-2","timestamp":1753350001}}
        """
        let event = try XCTUnwrap(BiliMessageMapper.map(messageBody: Data(json.utf8),
                                                        receivedAt: fallbackDate))

        XCTAssertEqual(event.kind, .gift)
        XCTAssertNil(event.value)
    }

    func testMapSuperChat() throws {
        let json = """
        {"cmd":"LIVE_OPEN_PLATFORM_SUPER_CHAT","data":{"uname":"金主","message":"主播加油",\
        "rmb":30,"msg_id":"sc-1","timestamp":1753350002}}
        """
        let event = try XCTUnwrap(BiliMessageMapper.map(messageBody: Data(json.utf8),
                                                        receivedAt: fallbackDate))

        XCTAssertEqual(event.kind, .superChat)
        XCTAssertEqual(event.user, "金主")
        XCTAssertEqual(event.text, "主播加油")
        XCTAssertEqual(event.value, 30.0)
        XCTAssertTrue(event.isHighValue)
    }

    func testMapGuard() throws {
        let json = """
        {"cmd":"LIVE_OPEN_PLATFORM_GUARD","data":{"user_info":{"uid":7,"uname":"舰长大人"},\
        "guard_level":3,"guard_num":1,"guard_unit":"月","msg_id":"gd-1","timestamp":1753350003}}
        """
        let event = try XCTUnwrap(BiliMessageMapper.map(messageBody: Data(json.utf8),
                                                        receivedAt: fallbackDate))

        XCTAssertEqual(event.kind, .member)
        XCTAssertEqual(event.user, "舰长大人")
        XCTAssertEqual(event.text, "开通舰长 ×1月")
        XCTAssertTrue(event.isHighValue)
    }

    func testMapLikeWithoutMsgIDUsesStableHash() throws {
        let json = """
        {"cmd":"LIVE_OPEN_PLATFORM_LIKE","data":{"uname":"路人甲","like_text":"为主播点赞了",\
        "timestamp":1753350004}}
        """
        let body = Data(json.utf8)
        let first = try XCTUnwrap(BiliMessageMapper.map(messageBody: body, receivedAt: fallbackDate))
        let second = try XCTUnwrap(BiliMessageMapper.map(messageBody: body, receivedAt: fallbackDate))

        XCTAssertEqual(first.kind, .like)
        XCTAssertEqual(first.text, "为主播点赞了")
        XCTAssertTrue(first.id.hasPrefix("bili-"))
        XCTAssertEqual(first.id, second.id) // 同报文重放 → 同 id（供去重）

        let other = """
        {"cmd":"LIVE_OPEN_PLATFORM_LIKE","data":{"uname":"路人乙","like_text":"为主播点赞了",\
        "timestamp":1753350004}}
        """
        let otherEvent = try XCTUnwrap(BiliMessageMapper.map(messageBody: Data(other.utf8),
                                                             receivedAt: fallbackDate))
        XCTAssertNotEqual(first.id, otherEvent.id)
    }

    func testMapEnterRoom() throws {
        let json = """
        {"cmd":"LIVE_OPEN_PLATFORM_ENTER_ROOM","data":{"uname":"新观众","timestamp":1753350005}}
        """
        let event = try XCTUnwrap(BiliMessageMapper.map(messageBody: Data(json.utf8),
                                                        receivedAt: fallbackDate))

        XCTAssertEqual(event.kind, .enter)
        XCTAssertEqual(event.user, "新观众")
        XCTAssertEqual(event.text, "进入直播间")
        XCTAssertFalse(event.isHighValue)
    }

    func testMissingTimestampFallsBackToReceivedAt() throws {
        let json = #"{"cmd":"LIVE_OPEN_PLATFORM_DM","data":{"uname":"u","msg":"m","msg_id":"dm-2"}}"#
        let event = try XCTUnwrap(BiliMessageMapper.map(messageBody: Data(json.utf8),
                                                        receivedAt: fallbackDate))
        XCTAssertEqual(event.timestamp, fallbackDate)
    }

    func testUnknownCmdIgnoredWithoutError() {
        let json = #"{"cmd":"LIVE_OPEN_PLATFORM_FANCY_NEW_THING","data":{"foo":"bar"}}"#
        XCTAssertNil(BiliMessageMapper.map(messageBody: Data(json.utf8), receivedAt: fallbackDate))
    }

    func testMalformedJSONIgnoredWithoutError() {
        XCTAssertNil(BiliMessageMapper.map(messageBody: Data("not json".utf8), receivedAt: fallbackDate))
    }
}
