// 首页 —— mockup 01 逐元素还原：大标题 / 渐变圆环眼镜 hero / 已连接行 /
// 三枚玻璃 chips / 玻璃列表卡四行（值来自 ViewState）/ 渐变描边"开始直播"CTA / 底部边界文案。
// 规格：F1 连接状态可见、F3/F5 配置摘要入口、F4 音源三选一、画质预设（spec-cards SpecHome）。
import SwiftUI
import AudioHub
import GlassesKit
import LensLiveCore

struct HomeScreen: View {
    @Environment(LiveSessionStore.self) private var store

    var body: some View {
        VStack(spacing: 16) {
            // 大标题
            Text("LensLive")
                .font(.system(.largeTitle, weight: .heavy))
                .foregroundStyle(LG.ink)
                .kerning(0.2)
                .frame(maxWidth: .infinity, alignment: .leading)

            heroSection

            configCard

            Spacer(minLength: 12)

            if let error = store.startError {
                Text(error)
                    .font(.system(.footnote, weight: .medium))
                    .foregroundStyle(LG.red)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }

            // 液态玻璃 CTA
            LGPrimaryCTA(title: "开始直播", isBusy: store.snapshot.phase == .preparing) {
                store.startLive()
            }

            // 底部边界文案（明确不做开播动作）
            Text("开播动作请先在 B 站直播姬完成 · 本机只负责推流")
                .font(.system(.caption))
                .foregroundStyle(LG.sec)
                .frame(maxWidth: .infinity)
                .padding(.top, -4)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .lgPage()
    }

    // MARK: - 渐变圆环 + 眼镜 hero + 连接状态 + chips

    private var heroSection: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(LG.grad)
                    .frame(width: 212, height: 212)
                Circle()
                    .fill(Color.white)
                    .frame(width: 206, height: 206)
                // 资产位：assets/glasses-hero.png（集成时以 Image("glasses-hero") 替换）
                Image(systemName: "eyeglasses")
                    .font(.system(size: 74, weight: .light))
                    .foregroundStyle(LG.ink.opacity(0.82))
            }
            .lgGlow()

            HStack(spacing: 7) {
                Circle()
                    .fill(glassesConnected ? LG.green : LG.ter)
                    .frame(width: 8, height: 8)
                Text(glassesConnected ? "已连接 · Ray-Ban Display" : "待连接 · Ray-Ban Display")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(LG.ink)
            }
            .accessibilityElement(children: .combine)

            HStack(spacing: 8) {
                LGChip(label: "温度 \(thermalLabel)")
                LGChip(label: "蓝牙 \(glassesConnected ? "稳定" : "待连接")")
                LGChip(label: "屏幕 \(store.snapshot.glassesHealth.displayReady || !store.snapshot.isSessionActive ? "就绪" : "掉线")")
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    private var glassesConnected: Bool {
        store.snapshot.glassesHealth.bluetoothLinkUp || store.isMockMode
    }

    private var thermalLabel: String {
        switch store.snapshot.glassesHealth.thermal {
        case .normal: return "正常"
        case .warm: return "偏暖"
        case .hot: return "偏高"
        case .critical: return "过热"
        }
    }

    // MARK: - 玻璃列表卡（推流目标 / 弹幕源 / 音源 / 画质）

    private var configCard: some View {
        VStack(spacing: 0) {
            // 跳转到对应 Tab 而非 push 副本，避免同屏双导航路径
            Button {
                store.selectedTab = .targets
            } label: {
                LGRow(icon: "target", title: "推流目标", value: store.selectedTarget.name)
            }
            .buttonStyle(.plain)

            Button {
                store.selectedTab = .danmaku
            } label: {
                LGRow(icon: "bubble.left", title: "弹幕源", value: "B 站 · 已绑定")
            }
            .buttonStyle(.plain)

            Menu {
                ForEach(AudioSource.allCases, id: \.self) { source in
                    Button {
                        store.setAudioSource(source)
                    } label: {
                        if source == store.audioSource {
                            Label(source.displayName, systemImage: "checkmark")
                        } else {
                            Text(source.displayName)
                        }
                    }
                }
            } label: {
                LGRow(icon: "mic", title: "音源", value: store.audioSource.displayName)
            }
            .buttonStyle(.plain)

            Menu {
                ForEach(CameraPreset.Quality.allCases, id: \.self) { quality in
                    Button {
                        store.setCameraQuality(quality)
                    } label: {
                        if quality == store.cameraPreset.quality {
                            Label(qualityLabel(quality), systemImage: "checkmark")
                        } else {
                            Text(qualityLabel(quality))
                        }
                    }
                }
            } label: {
                LGRow(icon: "photo", title: "画质", value: presetLabel(store.cameraPreset), isLast: true)
            }
            .buttonStyle(.plain)
        }
        .lgGlassCard()
    }

    private func presetLabel(_ preset: CameraPreset) -> String {
        let size = preset.pixelSize
        return "\(size.width)×\(size.height) · \(preset.frameRate)fps"
    }

    private func qualityLabel(_ quality: CameraPreset.Quality) -> String {
        let preset = CameraPreset(quality: quality, frameRate: store.cameraPreset.frameRate)
        let size = preset.pixelSize
        switch quality {
        case .high: return "高 · \(size.width)×\(size.height)"
        case .medium: return "中 · \(size.width)×\(size.height)"
        case .low: return "低 · \(size.width)×\(size.height)"
        }
    }
}

extension AudioSource {
    var displayName: String {
        switch self {
        case .iphoneMic: return "iPhone 麦克风"
        case .glassesHFP: return "眼镜麦克风（电话音质）"
        case .muted: return "静音"
        }
    }
}
