// 滑动窗口推流统计（纯逻辑，时间由调用方传入，可用虚拟时间单测）。
// 真实层：HaishinKitPipelineAdapter 在 appendVideoPayload 时喂帧，周期性 snapshot 上报 stats 流。
import Foundation

public struct StatsAggregator: Sendable {
    public var windowSeconds: TimeInterval
    public var targetBitrateMbps: Double

    private var sentFrames: [(time: TimeInterval, bytes: Int)] = []
    private var droppedFrames: [TimeInterval] = []
    private var firstRecordTime: TimeInterval?

    public init(windowSeconds: TimeInterval = 5, targetBitrateMbps: Double) {
        self.windowSeconds = windowSeconds
        self.targetBitrateMbps = targetBitrateMbps
    }

    /// 记录一帧进入管线（bytes 为该帧载荷大小）。
    public mutating func recordFrame(bytes: Int, at time: TimeInterval) {
        markFirstRecord(time)
        sentFrames.append((time, bytes))
        evict(before: time - windowSeconds)
    }

    public mutating func recordDropped(at time: TimeInterval) {
        markFirstRecord(time)
        droppedFrames.append(time)
        evict(before: time - windowSeconds)
    }

    public mutating func reset() {
        sentFrames.removeAll()
        droppedFrames.removeAll()
        firstRecordTime = nil
    }

    /// 窗口统计：fps = 窗口内进帧数/有效时长；bitrateMbps = 窗口内字节数换算；
    /// 丢帧比 = dropped/(sent+dropped)；networkGood = 丢帧 <5% 且码率 ≥ 目标 60%。
    /// 有效时长 = min(窗口, now - 首帧时间)，保证冷启动阶段不被窗口长度稀释。
    public func snapshot(at time: TimeInterval) -> StreamStats {
        let cutoff = time - windowSeconds
        let sent = sentFrames.filter { $0.time >= cutoff && $0.time <= time }
        let dropped = droppedFrames.filter { $0 >= cutoff && $0 <= time }

        let duration: TimeInterval
        if let first = firstRecordTime {
            duration = min(windowSeconds, time - first)
        } else {
            duration = 0
        }
        guard duration > 0 else {
            return StreamStats(bitrateMbps: 0, fps: 0, droppedFrameRatio: 0, networkGood: false)
        }

        let fps = Double(sent.count) / duration
        let bitrateMbps = Double(sent.reduce(0) { $0 + $1.bytes }) * 8 / duration / 1_000_000
        let total = sent.count + dropped.count
        let droppedRatio = total > 0 ? Double(dropped.count) / Double(total) : 0
        let networkGood = droppedRatio < 0.05 && bitrateMbps >= targetBitrateMbps * 0.6
        return StreamStats(bitrateMbps: bitrateMbps,
                           fps: fps,
                           droppedFrameRatio: droppedRatio,
                           networkGood: networkGood)
    }

    private mutating func markFirstRecord(_ time: TimeInterval) {
        if firstRecordTime == nil { firstRecordTime = time }
    }

    private mutating func evict(before cutoff: TimeInterval) {
        sentFrames.removeAll { $0.time < cutoff }
        droppedFrames.removeAll { $0 < cutoff }
    }
}
