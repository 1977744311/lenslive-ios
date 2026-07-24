// UI 消费的可观察快照聚合 —— Core 层只给纯 struct 流（Sendable/Equatable），
// @Observable 包装放 App 层（LiveSessionStore），符合"Core 纯逻辑、App 才碰 Observation"的分层。
import Foundation
import AudioHub
import DanmakuCore
import GlassRenderer
import GlassesKit
import StreamEngine

// MARK: - 眼镜健康（首页三枚 chips 与控制台状态的数据源）

public struct GlassesHealth: Sendable, Equatable {
    public var bluetoothLinkUp: Bool
    public var cameraStreaming: Bool
    public var displayReady: Bool
    public var thermal: ThermalLevel
    public var batteryCritical: Bool

    public init(bluetoothLinkUp: Bool = false,
                cameraStreaming: Bool = false,
                displayReady: Bool = false,
                thermal: ThermalLevel = .normal,
                batteryCritical: Bool = false) {
        self.bluetoothLinkUp = bluetoothLinkUp
        self.cameraStreaming = cameraStreaming
        self.displayReady = displayReady
        self.thermal = thermal
        self.batteryCritical = batteryCritical
    }
}

// MARK: - 带序号的通知（控制台横幅队列，id 递增保证 Identifiable 稳定）

public struct DatedNotice: Sendable, Equatable, Identifiable {
    public var id: Int
    public var notice: CoordinatorNotice
    public var postedAt: Date

    public init(id: Int, notice: CoordinatorNotice, postedAt: Date) {
        self.id = id
        self.notice = notice
        self.postedAt = postedAt
    }
}

// MARK: - 会话快照

public struct LiveSessionSnapshot: Sendable, Equatable {
    public var phase: LiveSessionPhase
    public var readiness: ReadinessBitmap
    /// 开播完成时刻（UI 可据此自行走秒；elapsed 为快照发出时的时长）
    public var startedAt: Date?
    public var elapsed: TimeInterval
    public var stats: StreamStats?
    public var glassesHealth: GlassesHealth
    /// 全量弹幕缓冲（F7：控制台不节流），上限见配置
    public var danmakuBuffer: [DanmakuEvent]
    public var filterMode: DanmakuFilterMode
    public var notices: [DatedNotice]
    public var cameraPreset: CameraPreset
    public var audioSource: AudioSource
    /// 在线人数（B 站开放平台无个人可用通道时为 nil，Mock/集成层可回填）
    public var viewers: Int?
    /// captouch backOnRoot → 手机端需弹"结束直播?"二次确认
    public var awaitingEndConfirmation: Bool

    public init(phase: LiveSessionPhase = .idle,
                readiness: ReadinessBitmap = ReadinessBitmap(),
                startedAt: Date? = nil,
                elapsed: TimeInterval = 0,
                stats: StreamStats? = nil,
                glassesHealth: GlassesHealth = GlassesHealth(),
                danmakuBuffer: [DanmakuEvent] = [],
                filterMode: DanmakuFilterMode = .all,
                notices: [DatedNotice] = [],
                cameraPreset: CameraPreset = .default,
                audioSource: AudioSource = .iphoneMic,
                viewers: Int? = nil,
                awaitingEndConfirmation: Bool = false) {
        self.phase = phase
        self.readiness = readiness
        self.startedAt = startedAt
        self.elapsed = elapsed
        self.stats = stats
        self.glassesHealth = glassesHealth
        self.danmakuBuffer = danmakuBuffer
        self.filterMode = filterMode
        self.notices = notices
        self.cameraPreset = cameraPreset
        self.audioSource = audioSource
        self.viewers = viewers
        self.awaitingEndConfirmation = awaitingEndConfirmation
    }

    public static let initial = LiveSessionSnapshot()

    // MARK: 便捷派生

    /// 会话是否存续（idle/ending 之外都算）
    public var isSessionActive: Bool {
        switch phase {
        case .idle, .ending: return false
        default: return true
        }
    }

    public var degradedSubsystems: Set<Subsystem> {
        if case .degraded(let missing) = phase { return missing }
        return []
    }

    /// 供 GlassScreenComposing / 眼镜预览复用的状态摘要
    public var statusSummary: LiveStatusSummary {
        LiveStatusSummary(elapsed: elapsed,
                          viewers: viewers,
                          bitrateMbps: stats?.bitrateMbps ?? 0,
                          fps: Int((stats?.fps ?? 0).rounded()),
                          networkGood: stats?.networkGood ?? true,
                          thermal: glassesHealth.thermal)
    }
}
