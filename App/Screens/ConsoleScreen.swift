// 直播控制台 —— mockup 02 逐元素还原：玻璃胶囊状态栏（红点 LIVE+时长 | 人数）/
// 渐变描边取景框 / 无气泡弹幕流 + 琥珀金 SC 胶囊卡 / 底部独立悬浮件（相机·结束直播·消息）/ notices 横幅。
// 规格：F2 推流监控、F7 全量弹幕流、F8 异常横幅；结束直播带二次确认（对应 captouch back 语义）。
import SwiftUI
import DanmakuCore
import LensLiveCore

struct ConsoleScreen: View {
    @Environment(LiveSessionStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showEndConfirm = false
    @State private var dismissedNoticeID = 0
    @State private var previewCollapsed = false

    var body: some View {
        VStack(spacing: 0) {
            statusBar
                .padding(.bottom, 14)

            if previewCollapsed {
                collapsedStatsBar
            } else {
                viewfinder
            }

            noticeBanner

            danmakuFeed

            dock
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .lgPage()
        // captouch backOnRoot → 手机端弹同一个确认（PRD F6）
        .onChange(of: store.snapshot.awaitingEndConfirmation) { _, awaiting in
            if awaiting { showEndConfirm = true }
        }
        .confirmationDialog("结束直播？", isPresented: $showEndConfirm, titleVisibility: .visible) {
            Button("结束直播", role: .destructive) { store.endLiveConfirmed() }
            Button("继续直播", role: .cancel) { store.cancelEndRequest() }
        } message: {
            Text("推流与弹幕连接将有序断开")
        }
        // 触觉反馈：开播成功一次 success；新异常横幅一次 warning（HIG：动作要有非视觉反馈）
        .sensoryFeedback(.success, trigger: store.snapshot.startedAt) { old, new in
            old == nil && new != nil
        }
        .sensoryFeedback(.warning, trigger: store.snapshot.notices.last?.id) { old, new in
            new != nil && old != new
        }
    }

    private var isPreparing: Bool {
        store.snapshot.phase == .preparing
    }

    // MARK: - 玻璃胶囊状态栏

    private var statusBar: some View {
        HStack {
            LGGlassCapsule {
                HStack(spacing: 10) {
                    if isPreparing {
                        // 连接尚未建立：不亮红 LIVE，给明确的进行中反馈
                        ProgressView()
                            .controlSize(.small)
                            .tint(LG.ink)
                        Text("准备中")
                            .font(.system(.subheadline, weight: .heavy))
                            .tracking(1.5)
                            .foregroundStyle(LG.ink)
                    } else {
                        Circle()
                            .fill(LG.red)
                            .frame(width: 9, height: 9)
                            .shadow(color: LG.red.opacity(0.55), radius: 4)
                        Text("LIVE")
                            .font(.system(.subheadline, weight: .heavy))
                            .tracking(1.5)
                            .foregroundStyle(LG.ink)
                        Rectangle()
                            .fill(LG.hair)
                            .frame(width: 1, height: 15)
                        // 走秒由 TimelineView 驱动，与快照 startedAt 对齐
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text(elapsedText)
                                .font(.system(.body, weight: .bold))
                                .monospacedDigit()
                                .kerning(0.5)
                                .foregroundStyle(LG.ink)
                        }
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(isPreparing ? "准备中" : "直播中，已进行 \(elapsedText)")
            Spacer()
            LGGlassCapsule {
                HStack(spacing: 7) {
                    Image(systemName: "person")
                        .font(.system(.footnote, weight: .medium))
                        .foregroundStyle(Color(hex: 0x14161C).opacity(0.5))
                    Text(viewersText)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(LG.ink)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("观众 \(viewersText)")
        }
    }

    private var elapsedText: String {
        guard let startedAt = store.snapshot.startedAt else { return "00:00:00" }
        let seconds = max(0, Int(Date().timeIntervalSince(startedAt)))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }

    private var viewersText: String {
        guard let viewers = store.snapshot.viewers else { return "—" }
        return viewers.formatted(.number.grouping(.automatic))
    }

    // MARK: - 渐变描边取景框（POV 预览层接口）

    private var viewfinder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color.black)
            // POV 预览接入位：集成阶段由 StreamEngine/GlassesKit 适配器提供
            // DAT 帧的本地渲染层（如 SampleBufferDisplayView）；Mock 模式显示占位。
            VStack(spacing: 10) {
                Image(systemName: "video")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Color.white.opacity(0.55))
                Text("POV 预览 · 等待眼镜相机帧")
                    .font(.system(.footnote))
                    .foregroundStyle(Color.white.opacity(0.55))
                HStack(spacing: 8) {
                    statChip(statBitrate)
                    statChip(statFps)
                    statChip(store.snapshot.stats?.networkGood == false ? "网络 波动" : "网络 良好")
                }
            }
        }
        .frame(height: 298)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .strokeBorder(LG.grad, lineWidth: 4)
                .padding(-4)
        }
        .lgGlow()
        .padding(.horizontal, 2)
    }

    /// 预览收起态：保留推流监控指标的紧凑条（腾出屏幕给弹幕流）
    private var collapsedStatsBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "video.slash")
                .font(.system(.caption, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.55))
            statChip(statBitrate)
            statChip(statFps)
            statChip(store.snapshot.stats?.networkGood == false ? "网络 波动" : "网络 良好")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(Capsule().fill(Color.black.opacity(0.86)))
        .padding(.horizontal, 2)
    }

    private var statBitrate: String {
        guard let stats = store.snapshot.stats else { return "-- Mbps" }
        return String(format: "%.1f Mbps", stats.bitrateMbps)
    }

    private var statFps: String {
        guard let stats = store.snapshot.stats else { return "-- fps" }
        return "\(Int(stats.fps.rounded())) fps"
    }

    private func statChip(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption2, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(Color.white.opacity(0.85))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(0.14)))
    }

    // MARK: - notices 横幅区（F8：每类异常用户可见，无静默失败）

    @ViewBuilder
    private var noticeBanner: some View {
        if let dated = store.snapshot.notices.last, dated.id != dismissedNoticeID {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(.caption, weight: .semibold))
                Text(dated.notice.bannerText)
                    .font(.system(.footnote, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Button {
                    dismissedNoticeID = dated.id
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(.caption2, weight: .bold))
                        .frame(width: 32, height: 32)   // 触达目标补足（胶囊自身高度有限）
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭提示")
            }
            .foregroundStyle(LG.gold)
            .padding(.leading, 14)
            .padding(.trailing, 4)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color(hex: 0xFFC44D).opacity(0.16)))
            .padding(.top, 10)
        }
    }

    // MARK: - 弹幕流（无气泡行 + 琥珀金 SC 胶囊卡）

    private var danmakuFeed: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 16) {
                    ForEach(store.snapshot.danmakuBuffer.suffix(60)) { event in
                        if event.isHighValue && event.kind != .chat {
                            SuperChatCard(event: event)
                                .id(event.id)
                        } else {
                            DanmakuRow(event: event, startedAt: store.snapshot.startedAt)
                                .id(event.id)
                        }
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 14)
            }
            .onChange(of: store.snapshot.danmakuBuffer.last?.id) { _, lastID in
                guard let lastID else { return }
                if reduceMotion {
                    proxy.scrollTo(lastID, anchor: .bottom)
                } else {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - 底部独立悬浮控制件（无 dock 底板）

    private var dock: some View {
        HStack(spacing: 14) {
            // 收起/展开 POV 预览（收起后弹幕流占满，指标条仍在）
            LGRoundGlassButton(systemName: previewCollapsed ? "video.slash" : "video") {
                if reduceMotion {
                    previewCollapsed.toggle()
                } else {
                    withAnimation(.spring(duration: 0.35)) {
                        previewCollapsed.toggle()
                    }
                }
            }
            .accessibilityLabel(previewCollapsed ? "展开 POV 预览" : "收起 POV 预览")
            Button {
                showEndConfirm = true
            } label: {
                Text("结束直播")
                    .font(.system(.body, weight: .heavy))
                    .tracking(2)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                    .background {
                        Capsule().fill(LG.endGrad)
                    }
                    .overlay {
                        Capsule().strokeBorder(Color.white.opacity(0.45), lineWidth: 1.5)
                            .blendMode(.plusLighter)
                    }
                    .shadow(color: LG.red.opacity(0.38), radius: 15, y: 12)
            }
            .buttonStyle(.plain)
            // 眼镜端过滤档循环：全部 → 仅高价值 → 暂停（与 captouch 单击语义一致）
            LGRoundGlassButton(systemName: filterIcon, tint: filterTint) {
                store.cycleFilterMode()
            }
            .accessibilityLabel("弹幕过滤")
            .accessibilityValue(store.snapshot.filterMode.displayName)
        }
        .padding(.horizontal, 2)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }

    private var filterIcon: String {
        switch store.snapshot.filterMode {
        case .all: return "message"
        case .highValueOnly: return "star"
        case .paused: return "pause"
        }
    }

    private var filterTint: Color? {
        switch store.snapshot.filterMode {
        case .all: return nil
        case .highValueOnly: return LG.gold
        case .paused: return LG.red
        }
    }
}

// MARK: - 弹幕行（概念稿 I：无气泡，头像 + 昵称灰 + 内容黑 + 右侧时间）

private struct DanmakuRow: View {
    let event: DanmakuEvent
    let startedAt: Date?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            LGAvatarPlaceholder(name: event.user, size: 42)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(event.user)
                        .font(.system(.footnote, weight: .medium))
                        .foregroundStyle(LG.sec)
                    Spacer()
                    Text(relativeTime)
                        .font(.system(.caption))
                        .monospacedDigit()
                        .foregroundStyle(LG.sec)
                }
                Text(event.text)
                    .font(.system(.callout))
                    .foregroundStyle(event.kind == .enter ? LG.sec : LG.ink)
                    .lineSpacing(3)
            }
            .padding(.top, 1)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    private var relativeTime: String {
        guard let startedAt else { return "--:--" }
        let seconds = max(0, Int(event.timestamp.timeIntervalSince(startedAt)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: - SC 胶囊卡（琥珀金，与眼镜端金卡语义统一）

private struct SuperChatCard: View {
    let event: DanmakuEvent

    var body: some View {
        HStack(spacing: 12) {
            LGAvatarPlaceholder(name: event.user, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 9) {
                    Text(event.user)
                        .font(.system(.subheadline, weight: .bold))
                        .foregroundStyle(LG.ink)
                    Text(badgeText)
                        .font(.system(.footnote, weight: .heavy))
                        .foregroundStyle(LG.gold)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 2.5)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: 0xFFC44D).opacity(0.20)))
                }
                Text(event.text)
                    .font(.system(.callout, weight: .medium))
                    .foregroundStyle(LG.ink)
            }
            Spacer(minLength: 6)
            Image(systemName: "star")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(Color(hex: 0xE3B23C))
        }
        .accessibilityElement(children: .combine)
        .padding(.leading, 13)
        .padding(.trailing, 20)
        .padding(.vertical, 12)
        .background {
            Capsule().fill(Color.white)
            Capsule().fill(LG.scCardFill)
        }
        .overlay {
            Capsule().strokeBorder(LG.goldGrad, lineWidth: 2)
        }
        .shadow(color: Color(hex: 0xFFAA40).opacity(0.28), radius: 15, y: 8)
        .shadow(color: Color(hex: 0xFF9240).opacity(0.22), radius: 8, y: 4)
    }

    private var badgeText: String {
        let amount = event.value.map { "¥\(Int($0))" } ?? ""
        switch event.kind {
        case .superChat: return "SC \(amount)"
        case .gift: return "礼物 \(amount)"
        case .member: return "舰长"
        default: return "高亮"
        }
    }
}

// MARK: - CoordinatorNotice → 横幅文案

extension CoordinatorNotice {
    var bannerText: String {
        switch self {
        case .rtmpReconnecting(let attempt): return "推流中断，正在第 \(attempt) 次重连…"
        case .rtmpGaveUp: return "推流重连已放弃，请检查网络后手动重试"
        case .bluetoothLost: return "眼镜蓝牙断开，等待自动重连…"
        case .bluetoothRecovered: return "眼镜已重连，画面已恢复"
        case .danmakuDisconnected: return "弹幕连接断开，自动重连中（直播不受影响）"
        case .danmakuRecovered: return "弹幕连接已恢复"
        case .thermalWarning(_, let preset):
            if let preset {
                let size = preset.pixelSize
                return "眼镜温度偏高，已自动降为 \(size.width)×\(size.height)"
            }
            return "眼镜温度偏高，建议阴凉处继续"
        case .batteryCritical: return "眼镜电量不足，请尽快收尾"
        case .interruptedBySystem: return "通话中，直播已暂停"
        case .resumed: return "已恢复直播"
        case .audioFallback(_, let to): return "眼镜麦克风不可用，已回退至\(to.displayName)"
        }
    }
}
