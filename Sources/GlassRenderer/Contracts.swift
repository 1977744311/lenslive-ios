// GlassRenderer 契约 —— 布局树严格对齐 DAT 六类组件与硬约束：
// 文字 3 字号（heading/body/meta）× 2 色（primary/secondary）；整屏替换；仅垂直滚动。
import Foundation
import GlassesKit
import DanmakuCore

// MARK: - 布局树（与 DAT FlexBox DSL 同构的中间表示）

public enum GlassTextStyle: String, Sendable, Codable { case heading, body, meta }
public enum GlassTextColor: String, Sendable, Codable { case primary, secondary }
public enum GlassDirection: String, Sendable, Codable { case column, row }
public enum GlassAlignment: String, Sendable, Codable { case start, center, end, stretch }
public enum GlassButtonStyle: String, Sendable, Codable { case primary, secondary, outline }
public enum GlassIconName: String, Sendable, Codable {
    case checkmarkCircle, bell, gear, heart, star, arrowLeft, arrowRight, gift, warning
}

public indirect enum GlassNode: Sendable, Equatable, Codable {
    case flexBox(FlexBoxProps, children: [GlassNode])
    case text(String, style: GlassTextStyle, color: GlassTextColor)
    case image(url: String)
    case button(label: String, style: GlassButtonStyle, actionID: String)
    case icon(GlassIconName)
}

public struct FlexBoxProps: Sendable, Equatable, Codable {
    public var direction: GlassDirection
    public var gap: Int
    public var alignment: GlassAlignment
    public var crossAlignment: GlassAlignment
    public var padding: Int
    /// 可点区域动作 ID（nil = 不可点）
    public var actionID: String?

    public init(direction: GlassDirection = .column, gap: Int = 0,
                alignment: GlassAlignment = .start, crossAlignment: GlassAlignment = .start,
                padding: Int = 0, actionID: String? = nil) {
        self.direction = direction
        self.gap = gap
        self.alignment = alignment
        self.crossAlignment = crossAlignment
        self.padding = padding
        self.actionID = actionID
    }
}

// MARK: - 屏幕模型（渲染入参）

public enum DanmakuFilterMode: String, Sendable, CaseIterable, Codable {
    case all          // 全部弹幕
    case highValueOnly // 仅 SC·礼物·提问
    case paused       // 暂停
    /// captouch 三档循环顺序
    public var next: DanmakuFilterMode {
        switch self {
        case .all: return .highValueOnly
        case .highValueOnly: return .paused
        case .paused: return .all
        }
    }
}

public struct LiveStatusSummary: Sendable, Equatable {
    public var elapsed: TimeInterval
    public var viewers: Int?
    public var bitrateMbps: Double
    public var fps: Int
    public var networkGood: Bool
    public var thermal: ThermalLevel

    public init(elapsed: TimeInterval, viewers: Int?, bitrateMbps: Double,
                fps: Int, networkGood: Bool, thermal: ThermalLevel) {
        self.elapsed = elapsed
        self.viewers = viewers
        self.bitrateMbps = bitrateMbps
        self.fps = fps
        self.networkGood = networkGood
        self.thermal = thermal
    }
}

// MARK: - 渲染器职责协议（实现：GlassScreenComposer 等）

/// 四屏布局生成 + 节流发送编排。实现方保证：
/// 1) 相同输入产出 canonicalJSON 稳定（快照测试）；2) 发送节流窗口内合并（默认 1s）；
/// 3) 高价值卡驻留期间普通刷新不覆盖卡片（驻留默认 8s）。
public protocol GlassScreenComposing: Sendable {
    func danmakuScreen(events: [DanmakuEvent], mode: DanmakuFilterMode,
                       status: LiveStatusSummary) -> GlassNode
    func highValueCard(event: DanmakuEvent, remaining: TimeInterval,
                       underlying: [DanmakuEvent], mode: DanmakuFilterMode,
                       status: LiveStatusSummary) -> GlassNode
    func statusScreen(status: LiveStatusSummary) -> GlassNode
    func alertScreen(fault: GlassesFault, degradedPreset: CameraPreset?) -> GlassNode
}

// MARK: - 序列化

public enum GlassNodeEncoder {
    /// 稳定（键排序）JSON —— DisplayPayload 与快照测试共用
    public static func canonicalJSON(_ node: GlassNode) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(node)
        return String(decoding: data, as: UTF8.self)
    }
}
