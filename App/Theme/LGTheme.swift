// LGTheme —— 手机端 v3 定稿视觉的设计 token 系统化（对齐 mockups/phone-screens-v3.jsx 的 LG 常量）。
// 语义：纯白极素基底 + 液态玻璃卡 + 主渐变(135° #12BEA4→#33CB7B→#8CDC52) + 琥珀金 SC + 红=直播状态。
import SwiftUI

// MARK: - Token

enum LG {
    // 基色
    static let bg = Color(hex: 0xFBFBFD)
    static let ink = Color(hex: 0x0B0B0F)
    static let sec = Color(hex: 0x14161C).opacity(0.55)
    static let ter = Color(hex: 0x14161C).opacity(0.32)
    static let hair = Color(hex: 0x14161C).opacity(0.08)
    static let red = Color(hex: 0xFF3B30)
    static let green = Color(hex: 0x34C759)
    static let gold = Color(hex: 0xC98A12)

    // 主渐变三色（linear 135°，中停点 48%）
    static let gradTeal = Color(hex: 0x12BEA4)
    static let gradGreen = Color(hex: 0x33CB7B)
    static let gradLime = Color(hex: 0x8CDC52)

    static var grad: LinearGradient {
        LinearGradient(stops: [
            .init(color: gradTeal, location: 0),
            .init(color: gradGreen, location: 0.48),
            .init(color: gradLime, location: 1),
        ], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static var gradSoft: LinearGradient {
        LinearGradient(stops: [
            .init(color: gradTeal.opacity(0.15), location: 0),
            .init(color: gradGreen.opacity(0.14), location: 0.48),
            .init(color: gradLime.opacity(0.16), location: 1),
        ], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // 琥珀金（SC 卡，与眼镜端金卡语义统一）
    static var goldGrad: LinearGradient {
        LinearGradient(stops: [
            .init(color: Color(hex: 0xFFC44D).opacity(0.9), location: 0),
            .init(color: Color(hex: 0xFFAA40).opacity(0.7), location: 0.5),
            .init(color: Color(hex: 0xFF9240).opacity(0.9), location: 1),
        ], startPoint: .leading, endPoint: .trailing)
    }

    static var scCardFill: LinearGradient {
        LinearGradient(stops: [
            .init(color: Color(hex: 0xFFE8BA).opacity(0.5), location: 0),
            .init(color: Color.white.opacity(0.22), location: 0.46),
            .init(color: Color(hex: 0xFFD89E).opacity(0.52), location: 1),
        ], startPoint: .leading, endPoint: .trailing)
    }

    // 结束直播红胶囊
    static var endGrad: LinearGradient {
        LinearGradient(colors: [Color(hex: 0xFF6A55), Color(hex: 0xF03B30)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

// MARK: - 页面底色：纯白 + 极淡绿系光晕（让玻璃有东西可折射）

struct LGPageBackground: View {
    var body: some View {
        ZStack {
            LG.bg
            RadialGradient(colors: [LG.gradTeal.opacity(0.10), .clear],
                           center: UnitPoint(x: 0.82, y: -0.04),
                           startRadius: 0, endRadius: 300)
            RadialGradient(colors: [LG.gradLime.opacity(0.11), .clear],
                           center: UnitPoint(x: 0.08, y: 1.08),
                           startRadius: 0, endRadius: 280)
            RadialGradient(colors: [LG.gradGreen.opacity(0.09), .clear],
                           center: UnitPoint(x: 0.92, y: 0.96),
                           startRadius: 0, endRadius: 240)
        }
        .ignoresSafeArea()
    }
}

extension View {
    func lgPage() -> some View {
        background(LGPageBackground())
    }
}

// MARK: - 液态玻璃卡（.ultraThinMaterial + 白washes + 内高光 + 可选渐变描边与彩色光晕）

struct LGGlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 24
    var tint = false
    var gradientBorder = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    if tint {
                        shape.fill(LG.gradSoft)
                    } else {
                        shape.fill(Color.white.opacity(0.66))
                    }
                }
            }
            .overlay {
                // 顶部内高光（inset 0 1px 0 白）
                shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.9), .white.opacity(0.25)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
            }
            .overlay {
                if gradientBorder {
                    RoundedRectangle(cornerRadius: cornerRadius + 2, style: .continuous)
                        .strokeBorder(LG.grad, lineWidth: 2)
                        .padding(-2)
                }
            }
            .shadow(color: Color(hex: 0x1E2232).opacity(0.07), radius: 15, y: 10)
            .modifier(LGGradientGlow(enabled: gradientBorder, soft: true))
    }
}

/// 主渐变彩色光晕（mock 的 LG.glow 三层投影）
struct LGGradientGlow: ViewModifier {
    var enabled = true
    /// soft = 卡片级（描边卡）；false = hero 级（圆环/取景框/CTA）
    var soft = false

    func body(content: Content) -> some View {
        if !enabled {
            content
        } else if soft {
            content
                .shadow(color: LG.gradTeal.opacity(0.26), radius: 14, y: 8)
                .shadow(color: LG.gradLime.opacity(0.20), radius: 9, y: 4)
        } else {
            content
                .shadow(color: LG.gradTeal.opacity(0.35), radius: 14, y: -6)
                .shadow(color: LG.gradGreen.opacity(0.32), radius: 15, y: 6)
                .shadow(color: LG.gradLime.opacity(0.30), radius: 23, y: 14)
        }
    }
}

extension View {
    func lgGlassCard(cornerRadius: CGFloat = 24, tint: Bool = false, gradientBorder: Bool = false) -> some View {
        modifier(LGGlassCardModifier(cornerRadius: cornerRadius, tint: tint, gradientBorder: gradientBorder))
    }

    func lgGlow() -> some View {
        modifier(LGGradientGlow(enabled: true, soft: false))
    }
}

// MARK: - 渐变 orb（live 指示）

struct LGOrb: View {
    var size: CGFloat = 12

    var body: some View {
        Circle()
            .fill(AngularGradient(colors: [LG.gradTeal, LG.gradGreen, LG.gradLime, LG.gradTeal],
                                  center: .center, angle: .degrees(210)))
            .frame(width: size, height: size)
            .shadow(color: LG.gradGreen.opacity(0.5), radius: 4)
    }
}

// MARK: - 玻璃 chip

struct LGChip: View {
    let label: String
    var dark = false

    var body: some View {
        Text(label)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(dark ? Color.white : LG.ink)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background {
                Capsule().fill(.ultraThinMaterial)
                Capsule().fill(dark ? Color(hex: 0x14161E).opacity(0.42) : Color.white.opacity(0.62))
            }
            .overlay {
                Capsule().strokeBorder(Color.white.opacity(dark ? 0.25 : 0.9), lineWidth: 0.5)
            }
            .shadow(color: Color(hex: 0x1E2232).opacity(0.06), radius: 4, y: 2)
    }
}

// MARK: - 玻璃胶囊（控制台状态栏等）

struct LGGlassCapsule<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 17)
            .padding(.vertical, 11)
            .background {
                Capsule().fill(.ultraThinMaterial)
                Capsule().fill(Color.white.opacity(0.68))
            }
            .overlay {
                Capsule().strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.95), .white.opacity(0.3)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
            }
            .shadow(color: Color(hex: 0x1E2232).opacity(0.10), radius: 12, y: 8)
    }
}

// MARK: - 列表行（玻璃卡内四行样式）

struct LGRow: View {
    var icon: String?
    let title: String
    let value: String
    var valueColor: Color = LG.sec
    var isLast = false
    var showsChevron = true

    var body: some View {
        HStack(spacing: 12) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Color(hex: 0x14161C).opacity(0.45))
                    .frame(width: 18)
            }
            Text(title)
                .font(.system(size: 16))
                .foregroundStyle(LG.ink)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 15))
                .foregroundStyle(valueColor)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LG.ter)
            }
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 55)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle()
                    .fill(LG.hair)
                    .frame(height: 0.5)
                    .padding(.leading, icon != nil ? 46 : 18)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - 渐变字（"如何获取推流地址?" 等入口）

struct LGGradientText: View {
    let text: String
    var size: CGFloat = 14.5
    var weight: Font.Weight = .bold

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(LG.grad)
    }
}

// MARK: - 主 CTA（开始直播胶囊：渐变描边 + 白底 + gradSoft 罩 + 顶部高光线）

struct LGPrimaryCTA: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(Color.white)
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(LG.gradSoft)
                VStack {
                    Rectangle()
                        .fill(Color.white.opacity(0.95))
                        .frame(height: 1)
                        .padding(.horizontal, 26)
                    Spacer()
                }
                Text(title)
                    .font(.system(size: 19, weight: .heavy))
                    .tracking(2)
                    .foregroundStyle(LG.ink)
            }
            .frame(height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .strokeBorder(LG.grad, lineWidth: 2)
                    .padding(-2)
            }
            .shadow(color: LG.gradTeal.opacity(0.38), radius: 18, y: 10)
            .shadow(color: LG.gradLime.opacity(0.28), radius: 25, y: 16)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 圆形玻璃控制键（控制台 dock 两侧）

struct LGRoundGlassButton: View {
    let systemName: String
    var tint: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(tint ?? Color(hex: 0x14161C).opacity(0.45))
                .frame(width: 58, height: 58)
                .background {
                    Circle().fill(.ultraThinMaterial)
                    Circle().fill(Color.white.opacity(0.72))
                }
                .overlay {
                    Circle().strokeBorder(
                        LinearGradient(colors: [.white, .white.opacity(0.3)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1)
                }
                .shadow(color: Color(hex: 0x1E2232).opacity(0.12), radius: 13, y: 10)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 头像占位（mock 资产位：assets/avatar-*.png；集成时替换为真实头像加载）

struct LGAvatarPlaceholder: View {
    let name: String
    var size: CGFloat = 42

    private var initial: String { String(name.prefix(1)) }

    var body: some View {
        Circle()
            .fill(LG.gradSoft)
            .overlay {
                Text(initial)
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(LG.gradGreen)
            }
            .overlay { Circle().strokeBorder(Color.white.opacity(0.8), lineWidth: 1) }
            .frame(width: size, height: size)
            .shadow(color: Color(hex: 0x1E2232).opacity(0.14), radius: 4, y: 2)
    }
}
