// 事件加工（纯逻辑，值类型可单测）：按 id 去重（LRU）、提问识别、可选过滤 enter/like。
import Foundation

public struct DanmakuAggregator: Sendable {
    public struct Configuration: Sendable {
        public var dedupCapacity: Int
        public var dropEnterEvents: Bool
        public var dropLikeEvents: Bool
        public var questionMarkers: [String]

        public init(dedupCapacity: Int = 512,
                    dropEnterEvents: Bool = false,
                    dropLikeEvents: Bool = false,
                    questionMarkers: [String] = ["问", "怎么", "多少", "哪", "吗", "？", "?"]) {
            self.dedupCapacity = dedupCapacity
            self.dropEnterEvents = dropEnterEvents
            self.dropLikeEvents = dropLikeEvents
            self.questionMarkers = questionMarkers
        }
    }

    private let configuration: Configuration
    private var recentIDs: LRUIDSet

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.recentIDs = LRUIDSet(capacity: configuration.dedupCapacity)
    }

    /// 返回加工后的事件；重复 / 被过滤时返回 nil。
    public mutating func process(_ event: DanmakuEvent) -> DanmakuEvent? {
        if configuration.dropEnterEvents, event.kind == .enter { return nil }
        if configuration.dropLikeEvents, event.kind == .like { return nil }
        guard recentIDs.insert(event.id) else { return nil }
        var annotated = event
        if !annotated.isQuestion,
           configuration.questionMarkers.contains(where: { annotated.text.contains($0) }) {
            annotated.isQuestion = true
        }
        return annotated
    }
}

/// 容量固定的最近 id 集合：命中即刷新新鲜度，超容淘汰最旧。
struct LRUIDSet: Sendable {
    private let capacity: Int
    private var order: [String] = []
    private var members: Set<String> = []

    init(capacity: Int) {
        self.capacity = capacity
    }

    /// 新 id 返回 true 并记录；已存在返回 false 并刷新其新鲜度。
    mutating func insert(_ id: String) -> Bool {
        if members.contains(id) {
            if let index = order.firstIndex(of: id) {
                order.remove(at: index)
                order.append(id)
            }
            return false
        }
        members.insert(id)
        order.append(id)
        if order.count > capacity {
            members.remove(order.removeFirst())
        }
        return true
    }
}
