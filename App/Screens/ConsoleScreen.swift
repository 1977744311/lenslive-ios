// 直播控制台 —— mockup 02 逐元素还原：玻璃胶囊状态栏（红点 LIVE+时长 | 人数）/
// 渐变描边取景框 / 无气泡弹幕流 + 琥珀金 SC 胶囊卡 / 底部独立悬浮件（相机·结束直播·消息）/ notices 横幅。
// 规格：F2 推流监控、F7 全量弹幕流、F8 异常横幅；结束直播带二次确认（对应 captouch back 语义）。
import SwiftUI
import DanmakuCore
import LensLiveCore

struct ConsoleScreen: View {
    @Environment(LiveSessionStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // 户外强光下夜航底不可读：外观可切浅色并记住偏好（默认保持夜航）
    @AppStorage("consoleLightAppearance") private var lightMode = false
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
        .background {
            if lightMode {
                LGPageBackground()
            } else {
                nightBackground
            }
        }
        .preferredColorScheme(lightMode ? .light : .dark)
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

    // 双外观语义色（浅色复用全局浅色 token，夜航保持原 token）
    private var inkC: Color { lightMode ? LG.ink : LG.nightInk }
    private var secC: Color { lightMode ? LG.sec : LG.nightSec }
    private var hairC: Color { lightMode ? LG.hair : LG.nightHair }

    // 夜航驾驶舱底色：深海军蓝 + 青绿星云微光（r2 自由设计稿）
    private var nightBackground: some View {
        ZStack {
            LG.nightBg
            RadialGradient(colors: [LG.gradTeal.opacity(0.14), .clear],
                           center: UnitPoint(x: 0.9, y: 0.05),
                           startRadius: 0, endRadius: 340)
            RadialGradient(colors: [LG.gradGreen.opacity(0.10), .clear],
                           center: UnitPoint(x: 0.06, y: 0.4),
                           startRadius: 0, endRadius: 300)
            RadialGradient(colors: [LG.gradTeal.opacity(0.08), .clear],
                           center: UnitPoint(x: 0.5, y: 1.05),
                           startRadius: 0, endRadius: 320)
        }
        .ignoresSafeArea()
    }

    // MARK: - 玻璃胶囊状态栏

    private var statusBar: some View {
        HStack(spacing: 10) {
            LGGlassCapsule(dark: !lightMode) {
                HStack(spacing: 10) {
                    if isPreparing {
                        // 连接尚未建立：不亮红 LIVE，给明确的进行中反馈
                        ProgressView()
                            .controlSize(.small)
                            .tint(inkC)
                        Text("准备中")
                            .font(.system(.subheadline, weight: .heavy))
                            .tracking(1.5)
                            .foregroundStyle(inkC)
                    } else {
                        Circle()
                            .fill(LG.red)
                            .frame(width: 9, height: 9)
                            .shadow(color: LG.red.opacity(0.8), radius: 5)
                        Text("LIVE")
                            .font(.system(.subheadline, weight: .heavy))
                            .tracking(1.5)
                            .foregroundStyle(inkC)
                        Rectangle()
                            .fill(hairC)
                            .frame(width: 1, height: 15)
                        // 走秒由 TimelineView 驱动，与快照 startedAt 对齐
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text(elapsedText)
                                .font(.system(.body, weight: .bold))
                                .monospacedDigit()
                                .kerning(0.5)
                                .foregroundStyle(inkC)
                        }
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(isPreparing ? "准备中" : "直播中，已进行 \(elapsedText)")
            Spacer(minLength: 0)
            LGGlassCapsule(dark: !lightMode) {
                HStack(spacing: 7) {
                    Image(systemName: "person")
                        .font(.system(.footnote, weight: .medium))
                        .foregroundStyle(secC)
                    Text(viewersText)
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundStyle(inkC)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("观众 \(viewersText)")
            appearanceToggle
        }
    }

    /// 外观切换：图标示意将切换到的模式（户外看不清夜航底时一键转浅色）
    private var appearanceToggle: some View {
        Button {
            if reduceMotion {
                lightMode.toggle()
            } else {
                withAnimation(.easeInOut(duration: 0.25)) {
                    lightMode.toggle()
                }
            }
        } label: {
            Image(systemName: lightMode ? "moon" : "sun.max")
                .font(.system(.subheadline, weight: .medium))
                .foregroundStyle(lightMode ? Color(hex: 0x14161C).opacity(0.45) : Color.white.opacity(0.85))
                .frame(width: 44, height: 44)
                .background {
                    Circle().fill(.ultraThinMaterial)
                    Circle().fill(lightMode ? Color.white.opacity(0.72) : Color(hex: 0x0D141E).opacity(0.72))
                }
                .overlay {
                    Circle().strokeBorder(
                        LinearGradient(colors: [.white.opacity(lightMode ? 1 : 0.25),
                                                .white.opacity(lightMode ? 0.3 : 0.06)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1)
                }
                .shadow(color: lightMode ? Color(hex: 0x1E2232).opacity(0.12) : Color.black.opacity(0.45),
                        radius: 13, y: 10)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(lightMode ? "切换到深色外观" : "切换到浅色外观")
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
                    .foregroundStyle(Color(hex: 0x8FE8CE).opacity(0.75))
                Text("POV 预览 · 等待眼镜相机帧")
                    .font(.system(.footnote))
                    .foregroundStyle(Color(hex: 0xB8D8CE).opacity(0.7))
                HStack(spacing: 8) {
                    statChip(statBitrate)
                    statChip(statFps)
                    statChip(store.snapshot.stats?.networkGood == false ? "网络 波动" : "网络 良好")
                }
            }
        }
        .frame(height: 298)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay {
            // r6 设计稿：发丝霓虹细边替代粗描边（r10 微调至 2.5）
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .strokeBorder(LG.grad, lineWidth: 2.5)
                .padding(-2.5)
        }
        .shadow(color: LG.gradTeal.opacity(0.35), radius: 12, y: -2)
        .shadow(color: LG.gradGreen.opacity(0.30), radius: 14, y: 4)
        .shadow(color: LG.gradLime.opacity(0.22), radius: 18, y: 8)
        .padding(.horizontal, 2)
    }

    /// 预览收起态：保留推流监控指标的紧凑条（腾出屏幕给弹幕流）
    private var collapsedStatsBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "video.slash")
                .font(.system(.caption, weight: .medium))
                .foregroundStyle(lightMode ? LG.sec : Color.white.opacity(0.55))
            statChip(statBitrate, onDark: !lightMode)
            statChip(statFps, onDark: !lightMode)
            statChip(store.snapshot.stats?.networkGood == false ? "网络 波动" : "网络 良好",
                     onDark: !lightMode)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background {
            if lightMode {
                Capsule().fill(.ultraThinMaterial)
                Capsule().fill(Color.white.opacity(0.70))
            } else {
                Capsule().fill(Color.black.opacity(0.86))
            }
        }
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

    /// onDark：chip 是否落在暗底上（取景框内恒为黑底；收起条跟随外观）
    private func statChip(_ text: String, onDark: Bool = true) -> some View {
        Text(text)
            .font(.system(.caption2, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(onDark ? Color.white.opacity(0.85) : LG.ink.opacity(0.75))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(onDark ? Color.white.opacity(0.14) : Color(hex: 0x14161C).opacity(0.07)))
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
                LazyVStack(spacing: 14) {
                    ForEach(store.snapshot.danmakuBuffer.suffix(60)) { event in
                        if event.isHighValue && event.kind != .chat {
                            SuperChatCard(event: event, dark: !lightMode)
                                .id(event.id)
                        } else {
                            DanmakuRow(event: event, startedAt: store.snapshot.startedAt, dark: !lightMode)
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
            LGRoundGlassButton(systemName: previewCollapsed ? "video.slash" : "video", dark: !lightMode) {
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
                        // r6 设计稿：亮红光环边替代白高光边
                        Capsule().strokeBorder(Color(hex: 0xFF7A66).opacity(0.85), lineWidth: 1.5)
                    }
                    // 夜航底上红胶囊要"发光"；浅色底上光环减淡为投影感
                    .shadow(color: LG.red.opacity(lightMode ? 0.30 : 0.60), radius: 18, y: 6)
                    .shadow(color: LG.red.opacity(lightMode ? 0.16 : 0.34), radius: 36, y: 0)
            }
            .buttonStyle(.plain)
            // 眼镜端过滤档循环：全部 → 仅高价值 → 暂停（与 captouch 单击语义一致）
            LGRoundGlassButton(systemName: filterIcon, tint: filterTint, dark: !lightMode) {
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
    var dark = true

    var body: some View {
        // 夜航：暗玻璃胶囊卡；浅色：白玻璃卡（与其余屏卡片语义一致）
        HStack(alignment: .top, spacing: 12) {
            LGAvatarPlaceholder(name: event.user, size: 40, dark: dark)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(event.user)
                        .font(.system(.footnote, weight: .medium))
                        .foregroundStyle(LG.gradGreen)
                    Spacer()
                    Text(relativeTime)
                        .font(.system(.caption))
                        .monospacedDigit()
                        .foregroundStyle(dark ? LG.nightSec : LG.sec)
                }
                Text(event.text)
                    .font(.system(.callout))
                    .foregroundStyle(event.kind == .enter
                                     ? (dark ? LG.nightSec : LG.sec)
                                     : (dark ? LG.nightInk : LG.ink))
                    .lineSpacing(3)
            }
            .padding(.top, 1)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background {
            // r10 设计稿：全胶囊形弹幕卡
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(dark ? AnyShapeStyle(LG.nightCard) : AnyShapeStyle(Color.white.opacity(0.78)))
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(dark ? LG.gradTeal.opacity(0.22) : LG.hair, lineWidth: 1)
        }
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
    var dark = true

    var body: some View {
        // 夜航：暗琥珀玻璃底；浅色：浅琥珀渐变底（scCardFill，金卡语义两端统一）
        HStack(spacing: 12) {
            LGAvatarPlaceholder(name: event.user, size: 44, dark: dark)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 9) {
                    Text(event.user)
                        .font(.system(.subheadline, weight: .bold))
                        .foregroundStyle(dark ? LG.nightInk : LG.ink)
                    // r6 设计稿：金底深字徽标，对比更强
                    Text(badgeText)
                        .font(.system(.footnote, weight: .heavy))
                        .foregroundStyle(Color(hex: 0x2A1B04))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(LG.goldGrad))
                }
                Text(event.text)
                    .font(.system(.callout, weight: .medium))
                    .foregroundStyle(dark ? LG.nightInk : LG.ink)
            }
            Spacer(minLength: 6)
            Image(systemName: "star")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(dark ? Color(hex: 0xFFD98A) : LG.gold)
                .shadow(color: Color(hex: 0xFFAA40).opacity(dark ? 0.6 : 0.35), radius: 6)
        }
        .accessibilityElement(children: .combine)
        .padding(.leading, 13)
        .padding(.trailing, 20)
        .padding(.vertical, 12)
        .background {
            if dark {
                Capsule().fill(Color(hex: 0x1A1206).opacity(0.85))
                Capsule().fill(LinearGradient(colors: [Color(hex: 0xFFC44D).opacity(0.14),
                                                       Color(hex: 0xFF9240).opacity(0.10)],
                                              startPoint: .leading, endPoint: .trailing))
            } else {
                Capsule().fill(Color.white.opacity(0.86))
                Capsule().fill(LG.scCardFill)
            }
        }
        .overlay {
            Capsule().strokeBorder(LG.goldGrad, lineWidth: 1)
        }
        .shadow(color: Color(hex: 0xFFAA40).opacity(dark ? 0.36 : 0.22), radius: 18, y: 4)
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
