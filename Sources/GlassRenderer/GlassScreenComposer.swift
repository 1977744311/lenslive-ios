// 四屏 GlassNode 树 —— 信息结构严格对齐 mockups/glass-frames.jsx。
// DAT 硬约束（display-capabilities.md §3/§8）：仅契约六类节点；
// 文字 3 字号 × 2 色；无透明度/自定义颜色/圆点图形——
// mockup 中的红点、金框、绿色数值、旧弹幕压暗等纯视觉均降级为语义表达。
import Foundation
import GlassesKit
import DanmakuCore

public struct GlassScreenComposer: GlassScreenComposing {

    /// 弹幕内容单条截断上限（含省略号）——保证眼镜端 ≤2 行
    public static let danmakuTextLimit = 60
    /// 弹幕主屏最多展示条数
    public static let danmakuListLimit = 6
    /// 高价值卡下方压缩展示的普通弹幕条数
    public static let underlyingListLimit = 2

    public init() {}

    // MARK: - 四屏

    public func danmakuScreen(events: [DanmakuEvent], mode: DanmakuFilterMode,
                              status: LiveStatusSummary) -> GlassNode {
        screenRoot(children: [
            statusLine(status: status, right: Self.filterModeLabel(mode)),
            danmakuList(events: events, limit: Self.danmakuListLimit),
            tapBar(mode: mode),
        ])
    }

    public func highValueCard(event: DanmakuEvent, remaining: TimeInterval,
                              underlying: [DanmakuEvent], mode: DanmakuFilterMode,
                              status: LiveStatusSummary) -> GlassNode {
        screenRoot(children: [
            statusLine(status: status, right: Self.filterModeLabel(mode)),
            goldCard(event: event, remaining: remaining),
            danmakuList(events: underlying, limit: Self.underlyingListLimit),
            tapBar(mode: mode),
        ])
    }

    public func statusScreen(status: LiveStatusSummary) -> GlassNode {
        screenRoot(children: [
            statusLine(status: status, right: "推流模式", showViewers: false),
            .flexBox(FlexBoxProps(direction: .column, gap: 8, alignment: .center, crossAlignment: .center),
                     children: [
                         .text("已直播", style: .meta, color: .secondary),
                         .text(GlassFormat.elapsed(status.elapsed), style: .heading, color: .primary),
                     ]),
            statRow([
                ("码率", GlassFormat.bitrate(status.bitrateMbps)),
                ("帧率", "\(status.fps) fps"),
            ]),
            statRow([
                ("网络", status.networkGood ? "良好" : "不稳定"),
                ("眼镜温度", GlassFormat.thermalLabel(status.thermal)),
            ]),
            .flexBox(FlexBoxProps(direction: .row, gap: 0, alignment: .center, crossAlignment: .center),
                     children: [
                         .text("当前平台无弹幕通道 · 互动请看手机", style: .meta, color: .secondary),
                     ]),
        ])
    }

    public func alertScreen(fault: GlassesFault, degradedPreset: CameraPreset?) -> GlassNode {
        let copy = Self.alertCopy(for: fault)
        var lines: [String] = []
        if let preset = degradedPreset {
            let size = preset.pixelSize
            lines.append("画质已自动降为 \(size.width)×\(size.height) · \(preset.frameRate)fps")
        }
        lines.append(copy.detail)
        return screenRoot(children: [
            // alertScreen 契约无 status 入参，状态行降级为静态语义（见集成报告）
            .flexBox(FlexBoxProps(direction: .row, gap: 12, crossAlignment: .center), children: [
                .icon(.checkmarkCircle),
                .text("LIVE", style: .meta, color: .primary),
                .text("推流中", style: .meta, color: .secondary),
            ]),
            .flexBox(FlexBoxProps(direction: .column, gap: 16, alignment: .center, crossAlignment: .center),
                     children: [.icon(.warning), .text(copy.title, style: .heading, color: .primary)]
                         + lines.map { .text($0, style: .body, color: .secondary) }),
            .flexBox(FlexBoxProps(direction: .row, gap: 12), children: [
                .button(label: "知道了", style: .primary, actionID: "ackAlert"),
                .button(label: "结束直播", style: .secondary, actionID: "endLive"),
            ]),
        ])
    }

    // MARK: - 共享构件

    private func screenRoot(children: [GlassNode]) -> GlassNode {
        .flexBox(FlexBoxProps(direction: .column, gap: 12, crossAlignment: .stretch, padding: 20),
                 children: children)
    }

    /// 顶部状态行：LIVE 红点语义 → icon+text（契约 icon 目录无圆点，用 checkmarkCircle 表达"直播进行中"）
    private func statusLine(status: LiveStatusSummary, right: String, showViewers: Bool = true) -> GlassNode {
        var children: [GlassNode] = [
            .icon(.checkmarkCircle),
            .text("LIVE", style: .meta, color: .primary),
            .text(GlassFormat.elapsed(status.elapsed), style: .meta, color: .secondary),
        ]
        if showViewers, let viewers = status.viewers {
            children.append(.text("在线 \(GlassFormat.viewers(viewers))", style: .meta, color: .secondary))
        }
        children.append(.text(right, style: .meta, color: .secondary))
        return .flexBox(FlexBoxProps(direction: .row, gap: 12, crossAlignment: .center), children: children)
    }

    /// 弹幕列表：底部对齐（alignment .end），最新在下
    private func danmakuList(events: [DanmakuEvent], limit: Int) -> GlassNode {
        .flexBox(FlexBoxProps(direction: .column, gap: 10, alignment: .end, crossAlignment: .stretch),
                 children: events.suffix(limit).map(danmakuItem))
    }

    private func danmakuItem(_ event: DanmakuEvent) -> GlassNode {
        .flexBox(FlexBoxProps(direction: .column, gap: 3), children: [
            .text(event.user, style: .meta, color: .secondary),
            .text(GlassFormat.truncate(event.text, limit: Self.danmakuTextLimit),
                  style: .body, color: .primary),
        ])
    }

    /// 高价值金卡（金框视觉降级为 icon+heading 语义）
    private func goldCard(event: DanmakuEvent, remaining: TimeInterval) -> GlassNode {
        .flexBox(FlexBoxProps(direction: .column, gap: 10, padding: 20), children: [
            .flexBox(FlexBoxProps(direction: .row, gap: 10, crossAlignment: .center), children: [
                .icon(Self.cardIcon(for: event)),
                .text(Self.cardHeadline(for: event), style: .heading, color: .primary),
                .text("驻留 \(Int(remaining.rounded()))s", style: .meta, color: .secondary),
            ]),
            .text(event.user, style: .meta, color: .secondary),
            .text(event.text, style: .body, color: .primary),
        ])
    }

    /// 底部三 tap 区，actionID 固定为 pause / cycleFilter / markRead
    private func tapBar(mode: DanmakuFilterMode) -> GlassNode {
        .flexBox(FlexBoxProps(direction: .row, gap: 12), children: [
            .button(label: "暂停", style: .secondary, actionID: "pause"),
            .button(label: Self.filterButtonLabel(mode), style: .primary, actionID: "cycleFilter"),
            .button(label: "已读", style: .secondary, actionID: "markRead"),
        ])
    }

    /// 2 格状态卡行（DAT 无 grid，用 row+column 组合表达 2×2）
    private func statRow(_ cells: [(String, String)]) -> GlassNode {
        .flexBox(FlexBoxProps(direction: .row, gap: 12, crossAlignment: .stretch),
                 children: cells.map { cell -> GlassNode in
                     .flexBox(FlexBoxProps(direction: .column, gap: 6, padding: 16), children: [
                         .text(cell.0, style: .meta, color: .secondary),
                         .text(cell.1, style: .body, color: .primary),
                     ])
                 })
    }

    // MARK: - 文案映射

    static func filterModeLabel(_ mode: DanmakuFilterMode) -> String {
        switch mode {
        case .all: "全部弹幕"
        case .highValueOnly: "仅 SC·礼物"
        case .paused: "已暂停"
        }
    }

    static func filterButtonLabel(_ mode: DanmakuFilterMode) -> String {
        switch mode {
        case .all: "过滤 · 全部"
        case .highValueOnly: "过滤 · SC"
        case .paused: "过滤 · 暂停"
        }
    }

    static func cardIcon(for event: DanmakuEvent) -> GlassIconName {
        event.kind == .gift ? .gift : .star
    }

    static func cardHeadline(for event: DanmakuEvent) -> String {
        switch event.kind {
        case .superChat: event.value.map { "SC \(GlassFormat.money($0))" } ?? "SC"
        case .gift: event.value.map { "礼物 \(GlassFormat.money($0))" } ?? "礼物"
        case .member: "开通舰长"
        default: "提问"
        }
    }

    static func alertCopy(for fault: GlassesFault) -> (title: String, detail: String) {
        switch fault {
        case .bluetoothLost:
            ("眼镜连接中断", "正在自动重连，画面可能短暂停止")
        case .thermal(let level):
            level >= .critical
                ? ("眼镜温度过高", "为保护设备，直播可能随时暂停")
                : ("眼镜温度偏高", "直播未中断，建议阴凉处继续")
        case .batteryCritical:
            ("眼镜电量严重不足", "请尽快为眼镜充电，直播可能随时中断")
        case .systemInterrupted:
            ("直播已被系统暂停", "来电或系统事件结束后将自动恢复")
        case .capabilityDenied:
            ("眼镜能力不可用", "请在 Meta AI app 中检查权限后重试")
        case .datAppUpdateRequired:
            ("眼镜端应用需要更新", "请在 Meta AI app 中更新眼镜端应用")
        }
    }
}

// MARK: - 确定性格式化（快照测试锁定）

enum GlassFormat {

    /// ≥1h → "01:07:23"；<1h → "23:41"
    static func elapsed(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let hours = total / 3600
        let minutes = total % 3600 / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%02d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }

    /// 1200 → "1.2k"；823 → "823"
    static func viewers(_ count: Int) -> String {
        count < 1000 ? "\(count)" : String(format: "%.1fk", Double(count) / 1000)
    }

    /// 50.0 → "¥50"；9.9 → "¥9.9"
    static func money(_ value: Double) -> String {
        value == value.rounded() ? "¥\(Int(value))" : String(format: "¥%.1f", value)
    }

    static func bitrate(_ mbps: Double) -> String {
        String(format: "%.1f Mbps", mbps)
    }

    static func thermalLabel(_ level: ThermalLevel) -> String {
        switch level {
        case .normal: "正常"
        case .warm: "微热"
        case .hot: "偏高"
        case .critical: "过热"
        }
    }

    /// 超限时截到 limit-1 个字符 + "…"，总长恰为 limit
    static func truncate(_ text: String, limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }
}
