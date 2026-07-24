// 音源路由状态机（AudioRouting 实现）。
// 官方顺序约束（research-live-danmaku.md §8.2）：HFP 路由建立后需等 2s 稳定窗口再校验，
// 且必须在相机流 start 之前完成——本控制器负责前半段（路由稳定 + 校验 + 回退），
// 时序编排由上层 SessionCoordinator 保证。
import Foundation

/// 状态机：inactive → configuring → (HFP: settling(2s) → verify) → active
///
/// - 切换语义：activate(new) 先 teardown 旧路由再建新路由；除 HFP 的 settling 稳定窗口
///   （默认 2s）外无其他等待，全程 ≤2s（时钟注入可测）。
/// - HFP 配置失败或稳定期后校验失败 → 发出 `.fallback(from: .glassesHFP, to: .iphoneMic)`
///   并自动激活 iPhone 麦。
/// - muted 无系统路由，直接 active。
/// - 稳定期内再次 activate/deactivate 会废弃进行中的旧流程（generation 守卫）。
public actor AudioRouteController: AudioRouting {
    public nonisolated var states: AsyncStream<AudioRouteState> { stateChannel.stream() }
    public var currentSource: AudioSource { current }

    private let ports: any AudioPortControlling
    private let clock: any AudioClock
    private let settleSeconds: TimeInterval

    private let stateChannel = AsyncBroadcast<AudioRouteState>()
    /// 契约注释：iphoneMic 为默认音源。
    private var current: AudioSource = .iphoneMic
    /// 并发 activate 的守卫：每次 activate/deactivate 自增，旧流程在每个 await 点后自检并让位。
    private var generation = 0

    public init(ports: any AudioPortControlling,
                clock: any AudioClock = SystemAudioClock(),
                hfpSettleSeconds: TimeInterval = 2.0) {
        self.ports = ports
        self.clock = clock
        self.settleSeconds = hfpSettleSeconds
    }

    // MARK: - AudioRouting

    @discardableResult
    public func activate(_ source: AudioSource) async -> AudioSource {
        generation += 1
        let gen = generation
        emit(.configuring)
        await ports.teardown() // 先停旧
        guard gen == generation else { return current }

        switch source {
        case .muted:
            current = .muted
            emit(.active(.muted))
            return .muted

        case .iphoneMic:
            return await activateIphoneMic(gen: gen)

        case .glassesHFP:
            do {
                try await ports.configureRoute(for: .glassesHFP)
            } catch {
                guard gen == generation else { return current }
                return await fallbackToIphoneMic(gen: gen, reason: "HFP 路由配置失败: \(error)")
            }
            guard gen == generation else { return current }

            emit(.settling(remaining: settleSeconds))
            do {
                try await clock.sleep(seconds: settleSeconds)
            } catch {
                return current // 流程被取消
            }
            guard gen == generation else { return current }

            let verified = await ports.verifyRoute(for: .glassesHFP)
            guard gen == generation else { return current }
            if verified {
                current = .glassesHFP
                emit(.active(.glassesHFP))
                return .glassesHFP
            }
            return await fallbackToIphoneMic(gen: gen, reason: "HFP 稳定期后路由校验失败")
        }
    }

    public func deactivate() async {
        generation += 1
        await ports.teardown()
        emit(.inactive)
    }

    // MARK: - 内部

    private func fallbackToIphoneMic(gen: Int, reason: String) async -> AudioSource {
        emit(.fallback(from: .glassesHFP, to: .iphoneMic, reason: reason))
        await ports.teardown() // 清掉半配置的 HFP 路由
        guard gen == generation else { return current }
        return await activateIphoneMic(gen: gen)
    }

    private func activateIphoneMic(gen: Int) async -> AudioSource {
        do {
            try await ports.configureRoute(for: .iphoneMic)
        } catch {
            guard gen == generation else { return current }
            // iPhone 麦是回退终点，再失败只能保底静音
            emit(.failed(reason: "iPhone 麦克风路由失败: \(error)"))
            current = .muted
            return .muted
        }
        guard gen == generation else { return current }
        current = .iphoneMic
        emit(.active(.iphoneMic))
        return .iphoneMic
    }

    private func emit(_ state: AudioRouteState) {
        stateChannel.yield(state)
    }
}
