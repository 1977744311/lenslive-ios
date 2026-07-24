// 上屏节流器（actor，Clock_ 注入）：窗口聚合批次输出 + 最近 N 条滚动缓冲 + 洪峰保护。
// 窗口惰性调度：首个事件到达才起定时器，空闲期无输出（配合眼镜休眠省电策略）。
import Foundation

public actor DanmakuThrottler {
    public struct Configuration: Sendable {
        public var windowSeconds: TimeInterval
        public var recentLimit: Int
        public var floodThreshold: Int

        public init(windowSeconds: TimeInterval = 1.0,
                    recentLimit: Int = 6,
                    floodThreshold: Int = 20) {
            self.windowSeconds = windowSeconds
            self.recentLimit = recentLimit
            self.floodThreshold = floodThreshold
        }
    }

    /// 窗口批次输出；shutdown 后结束。
    nonisolated public let batches: AsyncStream<[DanmakuEvent]>

    private let batchContinuation: AsyncStream<[DanmakuEvent]>.Continuation
    private let clock: any Clock_
    private let configuration: Configuration
    private var pending: [DanmakuEvent] = []
    private var recent: [DanmakuEvent] = []
    private var windowTask: Task<Void, Never>?
    private var isShutdown = false

    public init(configuration: Configuration = Configuration(),
                clock: any Clock_ = SystemClock()) {
        self.configuration = configuration
        self.clock = clock
        let (stream, continuation) = AsyncStream.makeStream(of: [DanmakuEvent].self)
        self.batches = stream
        self.batchContinuation = continuation
    }

    public func submit(_ event: DanmakuEvent) {
        guard !isShutdown else { return }
        pending.append(event)
        scheduleWindowIfNeeded()
    }

    /// 最近上屏的 N 条（默认 6），供整屏刷新 / 唤醒重发最后一屏。
    public func recentEvents() -> [DanmakuEvent] {
        recent
    }

    /// 当前窗口内尚未 flush 的事件数（观察用：诊断/测试确认窗口已结算）。
    public func pendingCount() -> Int {
        pending.count
    }

    public func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        windowTask?.cancel()
        windowTask = nil
        pending.removeAll()
        batchContinuation.finish()
    }

    private func scheduleWindowIfNeeded() {
        guard windowTask == nil else { return }
        windowTask = Task {
            let cancelled: Bool
            do {
                try await clock.sleep(seconds: configuration.windowSeconds)
                cancelled = false
            } catch {
                cancelled = true
            }
            windowTask = nil
            if !cancelled {
                flushWindow()
            }
        }
    }

    private func flushWindow() {
        guard !isShutdown, !pending.isEmpty else { return }
        var batch = pending
        pending.removeAll()
        if batch.count > configuration.floodThreshold {
            // 洪峰降级：只保高价值（SC/礼物/舰长/命中提问），普通弹幕整批丢弃。
            batch = batch.filter(\.isHighValue)
        }
        guard !batch.isEmpty else { return }
        recent.append(contentsOf: batch)
        if recent.count > configuration.recentLimit {
            recent.removeFirst(recent.count - configuration.recentLimit)
        }
        batchContinuation.yield(batch)
    }
}
