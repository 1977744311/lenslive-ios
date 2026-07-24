// 高价值卡驻留调度（actor + 时钟注入）。
// 新高价值事件 → 卡片态驻留 dwell 秒（默认 8s）；驻留期普通批次不打断
// （普通弹幕根本不进本调度器，消费方按当前意图渲染）；
// 到期回落 .danmaku；驻留中再来高价值 → FIFO 排队顺延，每张卡都足秒展示。
import Foundation
import GlassesKit
import DanmakuCore

/// 当前应显示的屏幕意图
public enum ScreenIntent: Sendable, Equatable {
    case danmaku
    case highValueCard(event: DanmakuEvent, remaining: TimeInterval)
}

public actor HighValueScheduler {

    private let dwell: TimeInterval
    private let clock: any Clock_
    private let bus = StreamBroadcaster<ScreenIntent>(replaysLatest: true)

    private var currentCard: DanmakuEvent?
    private var queue: [DanmakuEvent] = []
    private var dwellTask: Task<Void, Never>?

    public init(dwell: TimeInterval = 8, clock: any Clock_ = SystemClock()) {
        self.dwell = dwell
        self.clock = clock
        bus.send(.danmaku)   // 基线意图：新订阅者立即可渲染
    }

    /// 屏幕意图流（多订阅；新订阅者立即收到当前意图）
    public nonisolated var intents: AsyncStream<ScreenIntent> { bus.subscribe() }

    /// 喂入事件；非高价值事件直接忽略（防御上游漏筛）
    public func submit(_ event: DanmakuEvent) {
        guard event.isHighValue else { return }
        if currentCard == nil {
            show(event)
        } else {
            queue.append(event)
        }
    }

    public func stop() {
        dwellTask?.cancel()
        dwellTask = nil
        queue = []
        currentCard = nil
    }

    // MARK: - 内部

    private func show(_ event: DanmakuEvent) {
        currentCard = event
        bus.send(.highValueCard(event: event, remaining: dwell))
        dwellTask = Task { [dwell, clock] in
            do { try await clock.sleep(seconds: dwell) } catch { return }
            guard !Task.isCancelled else { return }
            await self.expire()
        }
    }

    private func expire() {
        dwellTask = nil
        if queue.isEmpty {
            currentCard = nil
            bus.send(.danmaku)
        } else {
            show(queue.removeFirst())
        }
    }
}
