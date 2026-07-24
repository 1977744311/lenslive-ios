// 推流会话核心状态机：驱动注入的 StreamPipelining，收敛断流退避重连。
import Foundation

/// 用户可见的重连通知（LensLiveCore 映射为 CoordinatorNotice.rtmpReconnecting / .rtmpGaveUp）。
public enum StreamSessionNotice: Sendable, Equatable {
    case reconnecting(attempt: Int)
    case gaveUp
}

/// 语义：
/// - `start` → 对外 `.connecting`；管线上报 `.streaming` 后对外 `.streaming`；重复 start 忽略（幂等）。
/// - 管线 `.failed`，或推流中意外 `.stopped` → 对外 `.reconnecting(attempt)` + 通知，按 BackoffPolicy
///   退避后 `pipeline.stop()` 复位再重试 `pipeline.start`；未回到 `.streaming` 前的连续失败累计
///   attempt，回到 `.streaming` 即清零。
/// - attempt 超过 maxAttempts → 对外 `.failed` + `.gaveUp` 通知，会话终止（之后可再次 start）。
/// - `stop` 任何状态可达 `.stopped`，并取消进行中的退避等待。
///
/// 对外 states 是控制器合成后的会话视图：管线的 `.idle/.connecting` 中间态不直接转发，
/// 避免重连期间对外状态在 reconnecting/connecting 间抖动；stats 原样转发管线统计。
public actor StreamSessionController {
    public nonisolated var states: AsyncStream<StreamPipelineState> { stateChannel.stream() }
    public nonisolated var stats: AsyncStream<StreamStats> { statsChannel.stream() }
    public nonisolated var notices: AsyncStream<StreamSessionNotice> { noticeChannel.stream() }

    public var currentState: StreamPipelineState { phase }

    private let pipeline: any StreamPipelining
    private let backoff: BackoffPolicy
    private let clock: any StreamClock

    private let stateChannel = AsyncBroadcast<StreamPipelineState>()
    private let statsChannel = AsyncBroadcast<StreamStats>()
    private let noticeChannel = AsyncBroadcast<StreamSessionNotice>()

    private var phase: StreamPipelineState = .idle
    /// 用户意图：start 置位；stop 或重连放弃后复位。
    private var isRunning = false
    /// 当前断流周期内已使用的重连次数（回到 streaming 即清零）。
    private var attempts = 0
    private var target: RTMPTarget?
    private var streamKey: String?
    private var reconnectTask: Task<Void, Never>?
    private var stateConsumer: Task<Void, Never>?
    private var statsConsumer: Task<Void, Never>?
    private var consumersStarted = false

    public init(pipeline: any StreamPipelining,
                backoff: BackoffPolicy = BackoffPolicy(),
                clock: any StreamClock = SystemStreamClock()) {
        self.pipeline = pipeline
        self.backoff = backoff
        self.clock = clock
    }

    /// 管线事件/统计的消费任务在首次 start 时挂载（Swift 6 不允许在
    /// 非隔离 init 里捕获 self 后再访问隔离属性；管线在 start 前也不会产生事件）。
    private func startConsumersIfNeeded() {
        guard !consumersStarted else { return }
        consumersStarted = true

        let pipelineStates = pipeline.states
        let pipelineStats = pipeline.stats
        let statsChannel = self.statsChannel
        stateConsumer = Task { [weak self] in
            for await state in pipelineStates {
                guard let self else { return }
                await self.handlePipelineState(state)
            }
        }
        // stats 纯转发，不经 actor 序列化，避免给帧路径统计加不必要的 hop
        statsConsumer = Task {
            for await sample in pipelineStats {
                statsChannel.yield(sample)
            }
        }
    }

    deinit {
        stateConsumer?.cancel()
        statsConsumer?.cancel()
        reconnectTask?.cancel()
    }

    // MARK: - 对外操作

    public func start(target: RTMPTarget, streamKey: String) async {
        guard !isRunning else { return }
        startConsumersIfNeeded()
        isRunning = true
        attempts = 0
        self.target = target
        self.streamKey = streamKey
        emit(.connecting)
        do {
            try await pipeline.start(target: target, streamKey: streamKey)
        } catch {
            scheduleReconnect(reason: "\(error)")
        }
    }

    public func stop() async {
        isRunning = false
        reconnectTask?.cancel()
        await pipeline.stop()
        emit(.stopped)
    }

    // MARK: - 管线事件

    private func handlePipelineState(_ state: StreamPipelineState) {
        guard isRunning else { return }
        switch state {
        case .streaming:
            attempts = 0
            emit(.streaming)
        case .failed(let reason):
            scheduleReconnect(reason: reason)
        case .stopped:
            // 只有"推流中"的 stopped 是断流；重连流程内部主动 stop 的余波不触发
            if phase == .streaming {
                scheduleReconnect(reason: "管线意外停止")
            }
        case .idle, .connecting, .reconnecting:
            break
        }
    }

    // MARK: - 重连

    private func scheduleReconnect(reason: String) {
        guard isRunning, reconnectTask == nil else { return }
        reconnectTask = Task { await self.reconnectLoop(initialReason: reason) }
    }

    private func reconnectLoop(initialReason: String) async {
        defer { reconnectTask = nil }
        var lastReason = initialReason
        while isRunning, !Task.isCancelled {
            attempts += 1
            guard let delay = backoff.delay(forAttempt: attempts) else {
                isRunning = false
                noticeChannel.yield(.gaveUp)
                emit(.failed(reason: lastReason))
                await pipeline.stop()
                return
            }
            emit(.reconnecting(attempt: attempts))
            noticeChannel.yield(.reconnecting(attempt: attempts))
            do {
                try await clock.sleep(seconds: delay)
            } catch {
                return // stop() 取消了退避等待
            }
            guard isRunning, !Task.isCancelled, let target, let streamKey else { return }
            await pipeline.stop() // 重试前复位管线（要求管线 stop 幂等）
            guard isRunning else { return }
            do {
                try await pipeline.start(target: target, streamKey: streamKey)
                return // 成功与否以管线后续事件为准：.streaming 清零；再失败则事件重入重连
            } catch {
                lastReason = "\(error)"
            }
        }
    }

    private func emit(_ next: StreamPipelineState) {
        guard next != phase else { return }
        phase = next
        stateChannel.yield(next)
    }
}
