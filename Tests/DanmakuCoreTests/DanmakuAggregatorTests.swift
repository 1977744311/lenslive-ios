import XCTest
import DanmakuCore

final class DanmakuAggregatorTests: XCTestCase {
    func testDuplicateIDDropped() {
        var aggregator = DanmakuAggregator()

        XCTAssertNotNil(aggregator.process(makeEvent(id: "a")))
        XCTAssertNil(aggregator.process(makeEvent(id: "a")))
        XCTAssertNotNil(aggregator.process(makeEvent(id: "b")))
    }

    func testLRUEvictionAndRefreshOnHit() {
        var aggregator = DanmakuAggregator(configuration: .init(dedupCapacity: 2))

        XCTAssertNotNil(aggregator.process(makeEvent(id: "a"))) // [a]
        XCTAssertNotNil(aggregator.process(makeEvent(id: "b"))) // [a,b]
        XCTAssertNil(aggregator.process(makeEvent(id: "a")))    // 命中，刷新 → [b,a]
        XCTAssertNotNil(aggregator.process(makeEvent(id: "c"))) // 淘汰 b → [a,c]
        XCTAssertNotNil(aggregator.process(makeEvent(id: "b"))) // b 已被淘汰，重新接受 → [c,b]
        XCTAssertNotNil(aggregator.process(makeEvent(id: "a"))) // a 被淘汰，重新接受
    }

    func testQuestionDetectionMarkers() {
        var aggregator = DanmakuAggregator()
        let questions = ["请问在哪里买", "怎么做到的", "这个多少钱", "是真的吗", "全角提问？", "why?"]

        for (index, text) in questions.enumerated() {
            let event = aggregator.process(makeEvent(id: "q\(index)", text: text))
            XCTAssertEqual(event?.isQuestion, true, "『\(text)』应命中提问")
            XCTAssertEqual(event?.isHighValue, true, "命中提问的 chat 应为高价值")
        }

        let plain = aggregator.process(makeEvent(id: "p1", text: "普通弹幕路过"))
        XCTAssertEqual(plain?.isQuestion, false)
        XCTAssertEqual(plain?.isHighValue, false)
    }

    func testPresetQuestionFlagPreserved() {
        var aggregator = DanmakuAggregator()
        let event = aggregator.process(makeEvent(id: "x", text: "无标记文本", isQuestion: true))
        XCTAssertEqual(event?.isQuestion, true)
    }

    func testOptionalEnterLikeFilters() {
        var filtering = DanmakuAggregator(
            configuration: .init(dropEnterEvents: true, dropLikeEvents: true)
        )
        XCTAssertNil(filtering.process(makeEvent(id: "e1", kind: .enter)))
        XCTAssertNil(filtering.process(makeEvent(id: "l1", kind: .like)))
        XCTAssertNotNil(filtering.process(makeEvent(id: "c1", kind: .chat)))

        var passthrough = DanmakuAggregator()
        XCTAssertNotNil(passthrough.process(makeEvent(id: "e2", kind: .enter)))
        XCTAssertNotNil(passthrough.process(makeEvent(id: "l2", kind: .like)))
    }

    func testEnterOnlyFilterKeepsLike() {
        var aggregator = DanmakuAggregator(configuration: .init(dropEnterEvents: true))
        XCTAssertNil(aggregator.process(makeEvent(id: "e", kind: .enter)))
        XCTAssertNotNil(aggregator.process(makeEvent(id: "l", kind: .like)))
    }
}
