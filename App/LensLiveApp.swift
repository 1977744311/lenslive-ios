// LensLive 入口 —— TabView/导航组装 + 依赖注入容器 + LiveSessionStore（@Observable 包装
// SessionCoordinator 的纯 struct 快照流；Core 层不碰 Observation，App 层在此桥接）。
// 当前以 Mock 模式组装（MockRuntime）；真机集成时替换为 App/Adapters 的真实适配器。
import SwiftUI
import AudioHub
import DanmakuCore
import GlassesKit
import GlassRenderer
import LensLiveCore
import StreamEngine

@main
struct LensLiveApp: App {
    @State private var store = LiveSessionStore.mock()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .tint(LG.gradGreen)
        }
    }
}

// MARK: - 根视图：三 Tab + 直播中全屏控制台

enum RootTab: Hashable {
    case home, targets, danmaku
}

struct RootView: View {
    @Environment(LiveSessionStore.self) private var store

    var body: some View {
        @Bindable var store = store
        TabView(selection: $store.selectedTab) {
            NavigationStack { HomeScreen() }
                .tabItem { Label("首页", systemImage: "eyeglasses") }
                .tag(RootTab.home)
            NavigationStack { TargetsScreen() }
                .tabItem { Label("推流目标", systemImage: "dot.radiowaves.left.and.right") }
                .tag(RootTab.targets)
            NavigationStack { DanmakuSettingsScreen() }
                .tabItem { Label("弹幕", systemImage: "bubble.left.and.bubble.right") }
                .tag(RootTab.danmaku)
        }
        .fullScreenCover(isPresented: consolePresented) {
            ConsoleScreen()
        }
    }

    /// 会话存续 = 控制台在场（phase 驱动，结束后自动收起）
    private var consolePresented: Binding<Bool> {
        Binding(
            get: { store.snapshot.isSessionActive },
            set: { presented in
                if !presented { store.endLiveConfirmed() }
            })
    }
}

// MARK: - 上屏参数（弹幕设置屏的可调项，开播时并入 LiveSessionConfiguration）

struct DanmakuUISettings {
    var displayLineCount = 6
    var displayThrottle: TimeInterval = 1
    var highValueDwell: TimeInterval = 8
    var highlightQuestions = true
    var blockEnterMessages = true
    var floodProtection = true
}

// MARK: - 连接测试状态

enum ConnectionTestState: Equatable {
    case notRun
    case testing
    case passed(ms: Int)
    case failed
}

// MARK: - LiveSessionStore

@MainActor
@Observable
final class LiveSessionStore {

    // 快照（Coordinator 输出流驱动）
    private(set) var snapshot: LiveSessionSnapshot = .initial

    // 根 Tab 选中态（首页配置行作跳转入口，避免与 Tab 重复导航）
    var selectedTab: RootTab = .home

    // 配置态（开播前的选择；开播后以快照为准）
    private(set) var targets: [RTMPTarget]
    private(set) var selectedTargetID: UUID
    var settings = DanmakuUISettings()
    private(set) var connectionTest: ConnectionTestState = .notRun
    private var preferredAudioSource: AudioSource = .iphoneMic
    private var preferredQuality: CameraPreset.Quality = .medium

    let isMockMode: Bool

    private let coordinator: SessionCoordinator
    private let composer: any GlassScreenComposing
    private let keychain = KeychainStore()
    private var observeTask: Task<Void, Never>?
    private var viewerTask: Task<Void, Never>?
    private var testTask: Task<Void, Never>?

    init(coordinator: SessionCoordinator,
         composer: any GlassScreenComposing,
         targets: [RTMPTarget],
         viewerFeed: AsyncStream<Int>?,
         isMockMode: Bool) {
        self.coordinator = coordinator
        self.composer = composer
        self.targets = targets
        self.selectedTargetID = targets[0].id
        self.isMockMode = isMockMode

        observeTask = Task { [coordinator] in
            let stream = await coordinator.snapshotStream()
            for await snap in stream {
                self.snapshot = snap
            }
        }
        if let viewerFeed {
            viewerTask = Task { [coordinator] in
                for await count in viewerFeed {
                    await coordinator.updateViewers(count)
                }
            }
        }
    }

    // Store 与 App 同生命周期，观察任务随进程结束回收（@MainActor deinit 无法触碰隔离属性）

    static func mock() -> LiveSessionStore {
        let components = MockRuntime.make()
        return LiveSessionStore(coordinator: components.coordinator,
                                composer: components.composer,
                                targets: MockRuntime.defaultTargets(),
                                viewerFeed: MockRuntime.makeViewerFeed(),
                                isMockMode: true)
    }

    // MARK: 派生读取（开播前显示偏好值，开播后跟随快照）

    var selectedTarget: RTMPTarget {
        targets.first { $0.id == selectedTargetID } ?? targets[0]
    }

    var audioSource: AudioSource {
        snapshot.isSessionActive ? snapshot.audioSource : preferredAudioSource
    }

    var cameraPreset: CameraPreset {
        snapshot.isSessionActive ? snapshot.cameraPreset
                                 : CameraPreset(quality: preferredQuality, frameRate: 24)
    }

    var hasStreamKey: Bool {
        isMockMode || keychain.hasValue(forKey: selectedTarget.streamKeyRef)
    }

    /// 眼镜端实时预览 = 与 Coordinator 相同的渲染树本地复算（所见即所得）
    var previewNode: GlassNode {
        let lineCount = settings.displayLineCount
        let visible: [DanmakuEvent]
        switch snapshot.filterMode {
        case .highValueOnly:
            visible = snapshot.danmakuBuffer.filter(\.isHighValue)
        default:
            visible = snapshot.danmakuBuffer.filter { event in
                if event.kind == .system { return false }
                if event.kind == .enter, settings.blockEnterMessages { return false }
                return true
            }
        }
        return composer.danmakuScreen(events: Array(visible.suffix(lineCount)),
                                      mode: snapshot.filterMode,
                                      status: snapshot.statusSummary)
    }

    // MARK: 会话动作

    func startLive() {
        let target = selectedTarget
        let streamKey = keychain.read(forKey: target.streamKeyRef)
            ?? (isMockMode ? "mock-stream-key" : "")
        let configuration = LiveSessionConfiguration(
            target: target,
            streamKey: streamKey,
            cameraPreset: CameraPreset(quality: preferredQuality, frameRate: 24),
            audioSource: preferredAudioSource,
            danmakuEnabled: target.preset != .custom,   // 自定义 RTMP（抖音）无合规弹幕通道
            displayLineCount: settings.displayLineCount,
            displayThrottle: settings.displayThrottle,
            highValueDwell: settings.highValueDwell,
            blockEnterMessages: settings.blockEnterMessages)
        Task { [coordinator] in
            do {
                try await coordinator.startLive(configuration: configuration)
            } catch {
                // glasses.start 失败：留在首页，连接状态行呈现未就绪（无静默失败）
            }
        }
    }

    func endLiveConfirmed() {
        Task { [coordinator] in await coordinator.confirmEndAndStop() }
    }

    func cancelEndRequest() {
        Task { [coordinator] in await coordinator.cancelEndRequest() }
    }

    func cycleFilterMode() {
        let next = snapshot.filterMode.next
        Task { [coordinator] in await coordinator.setFilterMode(next) }
    }

    func setAudioSource(_ source: AudioSource) {
        preferredAudioSource = source
        if snapshot.isSessionActive {
            Task { [coordinator] in await coordinator.setAudioSource(source) }
        }
    }

    func setCameraQuality(_ quality: CameraPreset.Quality) {
        preferredQuality = quality
        // 直播中手动改档（G4 恢复升档）为 P1：当前仅作用于下一场开播
    }

    // MARK: 推流目标管理

    func selectTarget(_ id: UUID) {
        guard targets.contains(where: { $0.id == id }) else { return }
        selectedTargetID = id
        connectionTest = .notRun
    }

    func updateServerURL(_ url: String) {
        guard let index = targets.firstIndex(where: { $0.id == selectedTargetID }) else { return }
        targets[index].serverURL = url
        connectionTest = .notRun
    }

    func saveStreamKey(_ key: String) {
        guard !key.isEmpty else { return }
        try? keychain.save(key, forKey: selectedTarget.streamKeyRef)
    }

    /// 连接测试：Mock 模式模拟握手延迟；真实实现待接 StreamEngine 的探测通道（TODO 集成）
    func runConnectionTest() {
        guard connectionTest != .testing else { return }
        let serverURL = selectedTarget.serverURL
        connectionTest = .testing
        testTask?.cancel()
        testTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            let valid = serverURL.hasPrefix("rtmp://") || serverURL.hasPrefix("rtmps://")
            connectionTest = (valid && serverURL.count > 10)
                ? .passed(ms: Int.random(in: 28...62))
                : .failed
        }
    }
}
