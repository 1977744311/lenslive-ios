// 弹幕设置 —— mockup 04 逐元素还原：眼镜端实时预览卡（GlassPreviewView 把 GlassRenderer
// 的 GlassNode 树用 SwiftUI 复刻渲染：600×600 等比缩放、黑底透视、text 三字号两色映射）/
// 数据源三行 / 上屏参数三行 / 过滤三开关。
// 规格：F5 数据源绑定、F6 上屏参数（条数 6 / 节流 1s / 驻留 8s）与过滤；预览=同一渲染树所见即所得。
import SwiftUI
import DanmakuCore
import GlassRenderer
import LensLiveCore

struct DanmakuSettingsScreen: View {
    @Environment(LiveSessionStore.self) private var store

    var body: some View {
        @Bindable var store = store
        ScrollView(showsIndicators: false) {
            VStack(spacing: 12) {
                Text("弹幕")
                    .font(.system(.title, weight: .heavy))
                    .foregroundStyle(LG.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 4)

                previewCard

                sourcesCard

                paramsCard

                filtersCard($store)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 32)   // 与悬浮 Tab 栏保持呼吸距离
        }
        .lgPage()
    }

    // MARK: - 眼镜端实时预览（同一 GlassNode 渲染树本地缩放，所见即所得）

    private var previewCard: some View {
        VStack(spacing: 10) {
            HStack {
                Text("眼镜端实时预览")
                    .font(.system(.caption))
                    .kerning(0.5)
                    .foregroundStyle(LG.sec)
                Spacer()
                Button {
                    store.cycleFilterMode()
                } label: {
                    LGGradientText(text: store.snapshot.filterMode.displayName, style: .caption)
                        .frame(minHeight: 44)   // 纯文字控件补足触达目标
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("弹幕过滤")
                .accessibilityValue(store.snapshot.filterMode.displayName)
            }
            // r4+r8 设计稿：预览放大 + 设备壳层（bezel）+ 波导微光；1:1 比例是硬件事实，不拉宽
            GlassPreviewView(node: store.previewNode)
                .frame(width: 224, height: 224)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(9)
                .background {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color(hex: 0x171B21))
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(
                            LinearGradient(colors: [LG.gradTeal.opacity(0.45),
                                                    Color.white.opacity(0.15),
                                                    LG.gradGreen.opacity(0.4)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: 1)
                }
                .shadow(color: LG.gradTeal.opacity(0.25), radius: 16, y: 4)
                .shadow(color: Color(hex: 0x1E2232).opacity(0.18), radius: 12, y: 8)
            Text("黑色区域在光波导上即透明（加色显示）")
                .font(.system(.caption2))
                .foregroundStyle(LG.sec)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .lgGlassCard(cornerRadius: 22)
    }

    // MARK: - 数据源

    private var sourcesCard: some View {
        // 品牌图标徽章与推流目标屏统一（r4 设计稿）
        VStack(spacing: 0) {
            LGRow(icon: "tv", iconTint: Color(hex: 0x00AEEC), title: "B 站",
                  value: biliConnected ? "已连接" : "未连接",
                  valueColor: biliConnected ? LG.green : LG.sec)
            LGRow(icon: "gamecontroller", iconTint: Color(hex: 0x9146FF), title: "Twitch", value: "未绑定")
            LGRow(icon: "play.rectangle.fill", iconTint: Color(hex: 0xFF0033), title: "YouTube", value: "未绑定", isLast: true)
        }
        .lgGlassCard(cornerRadius: 20)
    }

    private var biliConnected: Bool {
        store.snapshot.readiness.ready.contains(.danmaku) || store.isMockMode
    }

    // MARK: - 上屏参数（PRD F6 默认值：6 条 / 1s / 8s）

    private var paramsCard: some View {
        VStack(spacing: 0) {
            Menu {
                ForEach([5, 6, 7], id: \.self) { count in
                    Button("\(count) 条") { store.settings.displayLineCount = count }
                }
            } label: {
                LGRow(icon: "square.3.layers.3d", iconTint: LG.gradTeal,
                      title: "显示条数", value: "\(store.settings.displayLineCount) 条")
            }
            .buttonStyle(.plain)

            Menu {
                Button("0.5 秒") { store.settings.displayThrottle = 0.5 }
                Button("1 秒") { store.settings.displayThrottle = 1 }
            } label: {
                LGRow(icon: "arrow.trianglehead.2.clockwise", iconTint: LG.gradGreen,
                      title: "刷新节流", value: throttleLabel)
            }
            .buttonStyle(.plain)

            Menu {
                Button("8 秒") { store.settings.highValueDwell = 8 }
                Button("10 秒") { store.settings.highValueDwell = 10 }
            } label: {
                LGRow(icon: "star", iconTint: LG.gold,
                      title: "高价值卡驻留", value: "\(Int(store.settings.highValueDwell)) 秒", isLast: true)
            }
            .buttonStyle(.plain)
        }
        .lgGlassCard(cornerRadius: 20)
    }

    private var throttleLabel: String {
        store.settings.displayThrottle == 0.5 ? "0.5 秒" : "\(Int(store.settings.displayThrottle)) 秒"
    }

    // MARK: - 过滤三开关

    private func filtersCard(_ store: Bindable<LiveSessionStore>) -> some View {
        VStack(spacing: 0) {
            toggleRow("提问识别高亮", icon: "questionmark.bubble", tint: LG.gradTeal,
                      isOn: store.settings.highlightQuestions, isLast: false)
            toggleRow("屏蔽进场消息", icon: "person.slash", tint: LG.gradGreen,
                      isOn: store.settings.blockEnterMessages, isLast: false)
            toggleRow("洪峰保护", icon: "bolt.shield", tint: LG.gold,
                      isOn: store.settings.floodProtection, isLast: true)
        }
        .lgGlassCard(cornerRadius: 20)
    }

    private func toggleRow(_ title: String, icon: String, tint: Color,
                           isOn: Binding<Bool>, isLast: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(.footnote, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(tint.opacity(0.12))
                }
            Text(title)
                .font(.system(.callout))
                .foregroundStyle(LG.ink)
            Spacer()
            // 带标题的 Toggle + labelsHidden：视觉不变但 VoiceOver 能读到开关名称
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .tint(LG.green)
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 54)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle().fill(LG.hair).frame(height: 0.5).padding(.leading, 64)
            }
        }
    }
}

extension DanmakuFilterMode {
    var displayName: String {
        switch self {
        case .all: return "全部弹幕档"
        case .highValueOnly: return "仅 SC·礼物·提问"
        case .paused: return "已暂停"
        }
    }
}

// MARK: - GlassPreviewView：GlassNode 树 → SwiftUI 复刻渲染
// 600×600 逻辑画布等比缩放到目标尺寸；黑底（光波导加色显示上=透明）；
// text 三字号（heading 28 / body 18 / meta 13）两色（primary 白 / secondary #C6CAD2）
// 映射自官方 Display 规范（对齐 glass-frames.jsx 的 G 常量）。
// 注意：本视图内字号是物理眼镜屏的模拟，刻意不随 Dynamic Type 缩放。

struct GlassPreviewView: View {
    let node: GlassNode

    private static let canvas: CGFloat = 600

    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width, geo.size.height) / Self.canvas
            GlassNodeView(node: node)
                .frame(width: Self.canvas, height: Self.canvas, alignment: .topLeading)
                .background(Color.black)
                .scaleEffect(scale, anchor: .topLeading)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

struct GlassNodeView: View {
    let node: GlassNode

    var body: some View {
        switch node {
        case .flexBox(let props, let children):
            flexBoxView(props: props, children: children)
        case .text(let string, let style, let color):
            Text(string)
                .font(Self.font(for: style))
                .foregroundStyle(Self.color(for: color))
                .lineLimit(style == .body ? 2 : 1)
                .multilineTextAlignment(.leading)
        case .image(let url):
            // DAT image 组件占位（预览不加载远端资源）
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.12))
                .frame(width: 72, height: 72)
                .overlay {
                    Image(systemName: "photo")
                        .foregroundStyle(Color.white.opacity(0.4))
                }
                .accessibilityLabel(url)
        case .button(let label, let style, _):
            Text(label)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(style == .primary ? Color(hex: 0x111318) : .white)
                .frame(maxWidth: .infinity)
                .frame(height: 58)
                .background {
                    Capsule().fill(style == .primary
                                   ? Color(hex: 0xEEF1F5).opacity(0.92)
                                   : Color(hex: 0x1E232E).opacity(0.66))
                }
        case .icon(let name):
            Image(systemName: Self.symbol(for: name))
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white)
        }
    }

    @ViewBuilder
    private func flexBoxView(props: FlexBoxProps, children: [GlassNode]) -> some View {
        let content = ForEach(Array(children.enumerated()), id: \.offset) { _, child in
            GlassNodeView(node: child)
        }
        Group {
            if props.direction == .column {
                VStack(alignment: Self.hAlign(props.crossAlignment), spacing: CGFloat(props.gap)) {
                    if props.alignment == .center || props.alignment == .end { Spacer(minLength: 0) }
                    content
                    if props.alignment == .center { Spacer(minLength: 0) }
                }
            } else {
                HStack(alignment: Self.vAlign(props.crossAlignment), spacing: CGFloat(props.gap)) {
                    if props.alignment == .center || props.alignment == .end { Spacer(minLength: 0) }
                    content
                    if props.alignment == .center { Spacer(minLength: 0) }
                }
            }
        }
        .padding(CGFloat(props.padding))
        .frame(maxWidth: props.crossAlignment == .stretch || props.direction == .column ? .infinity : nil,
               alignment: Alignment(horizontal: Self.hAlign(props.crossAlignment), vertical: .top))
    }

    // MARK: 三字号两色映射（DAT 硬约束）

    private static func font(for style: GlassTextStyle) -> Font {
        switch style {
        case .heading: return .system(size: 28, weight: .bold)
        case .body: return .system(size: 18)
        case .meta: return .system(size: 13)
        }
    }

    private static func color(for color: GlassTextColor) -> Color {
        switch color {
        case .primary: return .white
        case .secondary: return Color(hex: 0xC6CAD2)
        }
    }

    private static func symbol(for icon: GlassIconName) -> String {
        switch icon {
        case .checkmarkCircle: return "checkmark.circle"
        case .bell: return "bell"
        case .gear: return "gearshape"
        case .heart: return "heart"
        case .star: return "star"
        case .arrowLeft: return "arrow.left"
        case .arrowRight: return "arrow.right"
        case .gift: return "gift"
        case .warning: return "exclamationmark.triangle"
        }
    }

    private static func hAlign(_ alignment: GlassAlignment) -> HorizontalAlignment {
        switch alignment {
        case .start, .stretch: return .leading
        case .center: return .center
        case .end: return .trailing
        }
    }

    private static func vAlign(_ alignment: GlassAlignment) -> VerticalAlignment {
        switch alignment {
        case .start, .stretch: return .top
        case .center: return .center
        case .end: return .bottom
        }
    }
}
