// 推流目标 —— mockup 03 逐元素还原：五张平台卡（选中绿描边+对钩）/ 当前配置卡
// （服务器等宽字体、密钥脱敏 ••••、连接测试行）/ "如何获取推流地址?"渐变字引导 sheet / 底部合规说明。
// 规格：F3 预设模板+多配置+Keychain 脱敏+图文引导；合规红线：不做推流码抓取/权限绕过。
import SwiftUI
import StreamEngine

struct TargetsScreen: View {
    @Environment(LiveSessionStore.self) private var store
    @State private var showGuide = false
    @State private var editingServer = false
    @State private var editingKey = false
    @State private var serverDraft = ""
    @State private var keyDraft = ""

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 10) {
                Text("推流目标")
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundStyle(LG.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 6)

                ForEach(store.targets) { target in
                    TargetCard(target: target, selected: target.id == store.selectedTarget.id) {
                        store.selectTarget(target.id)
                    }
                }

                configCard
                    .padding(.top, 8)

                Button {
                    showGuide = true
                } label: {
                    LGGradientText(text: "如何获取推流地址？")
                }
                .buttonStyle(.plain)
                .padding(.top, 8)

                Text("密钥仅存本机钥匙串 · 开播动作在平台官方工具完成")
                    .font(.system(size: 12))
                    .foregroundStyle(LG.ter)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 16)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
        }
        .lgPage()
        .sheet(isPresented: $showGuide) { GuideSheet() }
        .alert("服务器地址", isPresented: $editingServer) {
            TextField("rtmp://", text: $serverDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("保存") { store.updateServerURL(serverDraft) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("以 rtmp:// 或 rtmps:// 开头")
        }
        .alert("串流密钥", isPresented: $editingKey) {
            SecureField("粘贴串流密钥", text: $keyDraft)
            Button("保存") { store.saveStreamKey(keyDraft); keyDraft = "" }
            Button("取消", role: .cancel) { keyDraft = "" }
        } message: {
            Text("仅存本机钥匙串，界面永远脱敏显示")
        }
    }

    // MARK: - 当前配置卡

    private var configCard: some View {
        VStack(spacing: 0) {
            configRow(label: "服务器") {
                Text(store.selectedTarget.serverURL)
                    .font(.system(size: 13.5, design: .monospaced))
                    .foregroundStyle(LG.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .onTapGesture {
                serverDraft = store.selectedTarget.serverURL
                editingServer = true
            }

            Rectangle().fill(LG.hair).frame(height: 0.5).padding(.leading, 17)

            configRow(label: "串流密钥") {
                Text(store.hasStreamKey ? "••••••••" : "未配置")
                    .font(.system(size: 15))
                    .kerning(store.hasStreamKey ? 3 : 0)
                    .foregroundStyle(store.hasStreamKey ? LG.ink : LG.ter)
            }
            .onTapGesture { editingKey = true }

            Rectangle().fill(LG.hair).frame(height: 0.5).padding(.leading, 17)

            configRow(label: "连接测试") {
                switch store.connectionTest {
                case .notRun:
                    Text("点按测试")
                        .font(.system(size: 15))
                        .foregroundStyle(LG.sec)
                case .testing:
                    ProgressView().controlSize(.small)
                case .passed(let ms):
                    Text("通过 · \(ms)ms")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(LG.green)
                case .failed:
                    Text("失败 · 检查地址")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(LG.red)
                }
            }
            .onTapGesture { store.runConnectionTest() }
        }
        .lgGlassCard(cornerRadius: 20)
    }

    private func configRow(label: String, @ViewBuilder value: () -> some View) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 15))
                .foregroundStyle(LG.sec)
            Spacer(minLength: 12)
            value()
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }
}

// MARK: - 平台卡

private struct TargetCard: View {
    let target: RTMPTarget
    let selected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(target.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(LG.ink)
                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(LG.ter)
                }
                Spacer(minLength: 8)
                if selected {
                    ZStack {
                        Circle().fill(LG.grad)
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 24, height: 24)
                    .shadow(color: LG.gradGreen.opacity(0.5), radius: 5, y: 2)
                } else {
                    Circle()
                        .strokeBorder(Color(hex: 0x14161C).opacity(0.16), lineWidth: 1.5)
                        .frame(width: 22, height: 22)
                }
            }
            .padding(.horizontal, 17)
            .padding(.vertical, 15)
            .lgGlassCard(cornerRadius: 20, gradientBorder: selected)
        }
        .buttonStyle(.plain)
    }

    private var subtitle: String {
        switch target.preset {
        case .bilibiliLiveHime: return "局域网 rtmp://192.168.•.• · 适合 <5000 粉"
        case .bilibiliDirect: return "需 ≥5000 粉 · 直播中心获取地址"
        case .twitch: return "官方 ingest · 全球节点"
        case .youtube: return "官方 ingest"
        case .custom: return "抖音等：从 PC 直播伴侣获取临时码"
        }
    }
}

// MARK: - 图文引导 sheet（文案对齐 spec-cards：直播中心/直播姬/直播伴侣拿码要点）

private struct GuideSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    guideSection(
                        title: "B 站 · 直播姬中转（<5000 粉推荐）",
                        steps: [
                            "电脑打开直播姬，登录后选择「第三方推流」模式",
                            "直播姬会给出局域网 RTMP 地址（rtmp://192.168.…）与密钥",
                            "手机与电脑连同一 WiFi，把地址与密钥填入本页",
                            "开播动作在直播姬里点「开始直播」，本机只负责推流",
                        ])
                    guideSection(
                        title: "B 站 · 直接推流（≥5000 粉）",
                        steps: [
                            "网页登录 B 站「直播中心」→ 开播设置",
                            "满足粉丝门槛后可见「rtmp 地址 + 串流密钥」",
                            "复制两项填入本页，先在直播中心开播再开始推流",
                        ])
                    guideSection(
                        title: "抖音 · PC 直播伴侣（仅推流）",
                        steps: [
                            "电脑登录「直播伴侣」，选择第三方推流开播",
                            "每场直播生成一次性推流地址与临时码，有效期一场",
                            "抖音无合规弹幕通道：眼镜端将使用纯推流状态屏",
                        ])
                    Text("合规边界：本 App 不内置任何平台推流码抓取或权限绕过；开播动作一律在平台官方工具完成。")
                        .font(.system(size: 12.5))
                        .foregroundStyle(LG.ter)
                        .padding(.top, 4)
                }
                .padding(20)
            }
            .navigationTitle("如何获取推流地址")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func guideSection(title: String, steps: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(LG.ink)
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(LG.gradGreen)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(LG.gradGreen.opacity(0.12)))
                    Text(step)
                        .font(.system(size: 14.5))
                        .foregroundStyle(LG.ink.opacity(0.85))
                        .lineSpacing(3)
                }
            }
        }
    }
}
