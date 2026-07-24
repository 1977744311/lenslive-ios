import Testing
@testable import StreamEngine

@Suite("StatsAggregator")
struct StatsAggregatorTests {
    /// 满窗口：30fps × 5s，每帧 18750B → 4.5Mbps，正好达标
    @Test func fullWindowFpsAndBitrate() {
        var agg = StatsAggregator(targetBitrateMbps: 4.5)
        for i in 0..<150 {
            agg.recordFrame(bytes: 18_750, at: Double(i) / 30.0)
        }
        let stats = agg.snapshot(at: 5.0)
        #expect(abs(stats.fps - 30.0) < 0.001)
        #expect(abs(stats.bitrateMbps - 4.5) < 0.001)
        #expect(stats.droppedFrameRatio == 0)
        #expect(stats.networkGood)
    }

    /// 冷启动：有效时长按 now-首帧 计，1 秒 24 帧就是 24fps，不被 5s 窗口稀释
    @Test func warmupUsesElapsedTimeNotWindowLength() {
        var agg = StatsAggregator(targetBitrateMbps: 4.5)
        for i in 0..<24 {
            agg.recordFrame(bytes: 12_500, at: Double(i) / 24.0)
        }
        let stats = agg.snapshot(at: 1.0)
        #expect(abs(stats.fps - 24.0) < 0.001)
        #expect(abs(stats.bitrateMbps - 2.4) < 0.001)
        // 码率 2.4 < 4.5×60%=2.7 → 网络不佳
        #expect(!stats.networkGood)
    }

    /// 滑动窗口：超龄样本被剔除
    @Test func slidingWindowEvictsOldSamples() {
        var agg = StatsAggregator(targetBitrateMbps: 4.5)
        agg.recordFrame(bytes: 50_000, at: 0.0)
        agg.recordFrame(bytes: 50_000, at: 1.0)
        agg.recordDropped(at: 2.0)
        let stats = agg.snapshot(at: 10.0)
        #expect(stats.fps == 0)
        #expect(stats.bitrateMbps == 0)
        #expect(stats.droppedFrameRatio == 0)
        #expect(!stats.networkGood)
    }

    /// 丢帧比边界：4% 通过、5% 不通过（判定为 <5% 严格小于）
    @Test func droppedRatioBoundaryAtFivePercent() {
        var goodAgg = StatsAggregator(targetBitrateMbps: 4.5)
        for i in 0..<96 {
            goodAgg.recordFrame(bytes: 15_000, at: Double(i) * 4.0 / 96.0)
        }
        for i in 0..<4 {
            goodAgg.recordDropped(at: 3.9 + Double(i) * 0.01)
        }
        let good = goodAgg.snapshot(at: 4.0)
        #expect(abs(good.droppedFrameRatio - 0.04) < 0.0001)
        #expect(good.bitrateMbps >= 4.5 * 0.6)
        #expect(good.networkGood)

        var badAgg = StatsAggregator(targetBitrateMbps: 4.5)
        for i in 0..<95 {
            badAgg.recordFrame(bytes: 15_000, at: Double(i) * 4.0 / 95.0)
        }
        for i in 0..<5 {
            badAgg.recordDropped(at: 3.9 + Double(i) * 0.01)
        }
        let bad = badAgg.snapshot(at: 4.0)
        #expect(abs(bad.droppedFrameRatio - 0.05) < 0.0001)
        #expect(bad.bitrateMbps >= 4.5 * 0.6) // 码率仍达标，networkGood 仅因丢帧比失败
        #expect(!bad.networkGood)
    }

    /// 码率达到目标 60% 是 networkGood 的另一必要条件
    @Test func networkGoodRequiresSixtyPercentOfTargetBitrate() {
        var agg = StatsAggregator(targetBitrateMbps: 2.4)
        // 24 帧 × 7500B × 8 / 1s = 1.44Mbps，正好 60% → 达标（≥ 为闭区间）
        for i in 0..<24 {
            agg.recordFrame(bytes: 7_500, at: Double(i) / 24.0)
        }
        let atBoundary = agg.snapshot(at: 1.0)
        #expect(abs(atBoundary.bitrateMbps - 1.44) < 0.001)
        #expect(atBoundary.networkGood)

        var lowAgg = StatsAggregator(targetBitrateMbps: 2.4)
        for i in 0..<24 {
            lowAgg.recordFrame(bytes: 7_000, at: Double(i) / 24.0)
        }
        #expect(!lowAgg.snapshot(at: 1.0).networkGood)
    }

    @Test func emptyAndResetStatesAreZero() {
        var agg = StatsAggregator(targetBitrateMbps: 4.5)
        let empty = agg.snapshot(at: 0)
        #expect(empty == StreamStats(bitrateMbps: 0, fps: 0, droppedFrameRatio: 0, networkGood: false))

        agg.recordFrame(bytes: 10_000, at: 0.5)
        agg.reset()
        let afterReset = agg.snapshot(at: 1.0)
        #expect(afterReset == StreamStats(bitrateMbps: 0, fps: 0, droppedFrameRatio: 0, networkGood: false))
    }
}
