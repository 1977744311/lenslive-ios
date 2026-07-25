import Foundation
import Testing
import GlassesKit

@Suite("StreamBroadcaster 缓冲策略")
struct StreamBroadcasterTests {

    @Test("bufferingNewest：慢消费者只保留最新 N 条（帧流丢旧保新）")
    func dropsOldestWhenBufferBounded() async {
        let bus = StreamBroadcaster<Int>(bufferingPolicy: .bufferingNewest(2))
        let stream = bus.subscribe()
        var iterator = stream.makeAsyncIterator()

        // 订阅建立但不消费，连发 4 条：缓冲上限 2 → 1、2 被丢弃
        for value in 1...4 { bus.send(value) }
        bus.finish()

        var received: [Int] = []
        while let value = await iterator.next() {
            received.append(value)
        }
        #expect(received == [3, 4])
    }

    @Test("默认 unbounded：不丢任何值")
    func unboundedKeepsEverything() async {
        let bus = StreamBroadcaster<Int>()
        let stream = bus.subscribe()
        var iterator = stream.makeAsyncIterator()

        for value in 1...4 { bus.send(value) }
        bus.finish()

        var received: [Int] = []
        while let value = await iterator.next() {
            received.append(value)
        }
        #expect(received == [1, 2, 3, 4])
    }
}
