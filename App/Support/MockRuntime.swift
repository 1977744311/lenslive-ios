// MockRuntime —— App 以 Mock 模式可跑的组装件：
// MockGlassesSession（GlassesKit 提供）+ 假弹幕发生器 + 假推流管线 + 假音源路由 +
// 真 GlassScreenComposer，让四屏在模拟器里有活数据。
// TODO(集成): 真机阶段替换为 App/Adapters/GlassesDAT 与 App/Adapters/Streaming 的真实适配器。
import Foundation
import AudioHub
import DanmakuCore
import GlassRenderer
import GlassesKit
import LensLiveCore
import StreamEngine

// MARK: - 假弹幕发生器（定时产 DanmakuEvent 模拟直播间，语料对齐 mockup）

actor FakeDanmakuConnector: DanmakuConnector {
    nonisolated let platform: DanmakuPlatform = .bilibili
    nonisolated let events: AsyncStream<DanmakuEvent>
    nonisolated let states: AsyncStream<ConnectorState>

    private let eventsCont: AsyncStream<DanmakuEvent>.Continuation
    private let statesCont: AsyncStream<ConnectorState>.Continuation
    private var generator: Task<Void, Never>?

    private static let users = [
        "山间旅行者", "草莓泡芙", "晚风轻拂", "骑行的老王", "momo", "不吃香菜", "Nova_7", "阿云",
    ]
    private static let texts = [
        "哇！这视角也太棒了吧 👀",
        "拍得好清楚，像在现场一样",
        "主播去的是什么地方呀？好美！",
        "这条路秋天来更好看",
        "主播今天走了多少公里了？",
        "左边那家店上次你推荐过！",
        "声音很清楚，继续继续",
        "问一下机位是眼镜拍的吗，太稳了",
    ]

    init() {
        (events, eventsCont) = AsyncStream.makeStream(of: DanmakuEvent.self)
        (states, statesCont) = AsyncStream.makeStream(of: ConnectorState.self)
    }

    func start() async {
        statesCont.yield(.connecting)
        statesCont.yield(.connected)
        generator?.cancel()
        generator = Task { [eventsCont] in
            var index = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64.random(in: 900_000_000...2_400_000_000))
                if Task.isCancelled { break }
                eventsCont.yield(Self.makeEvent(index: index))
                index += 1
            }
        }
    }

    func stop() async {
        generator?.cancel()
        generator = nil
        statesCont.yield(.stopped)
    }

    private static func makeEvent(index: Int) -> DanmakuEvent {
        // 每 9 条穿插一张 SC（对齐 mockup 的琥珀金卡示例）
        if index % 9 == 8 {
            return DanmakuEvent(id: "mock-sc-\(index)", platform: .bilibili, kind: .superChat,
                                user: "星际漫游者", text: "超赞的直播！一直在跟～",
                                value: 30, timestamp: Date())
        }
        let text = texts[index % texts.count]
        return DanmakuEvent(id: "mock-\(index)", platform: .bilibili, kind: .chat,
                            user: users[index % users.count], text: text,
                            timestamp: Date(),
                            isQuestion: text.contains("？") || text.contains("吗"))
    }
}

// MARK: - 假推流管线（连接即 streaming，1Hz 产 stats）

actor FakeStreamPipeline: StreamPipelining {
    nonisolated let states: AsyncStream<StreamPipelineState>
    nonisolated let stats: AsyncStream<StreamStats>

    private let statesCont: AsyncStream<StreamPipelineState>.Continuation
    private let statsCont: AsyncStream<StreamStats>.Continuation
    private var statsTask: Task<Void, Never>?

    init() {
        (states, statesCont) = AsyncStream.makeStream(of: StreamPipelineState.self)
        (stats, statsCont) = AsyncStream.makeStream(of: StreamStats.self)
    }

    func start(target: RTMPTarget, streamKey: String) async throws {
        statesCont.yield(.connecting)
        statesCont.yield(.streaming)
        statsTask?.cancel()
        statsTask = Task { [statsCont] in
            while !Task.isCancelled {
                statsCont.yield(StreamStats(bitrateMbps: Double.random(in: 2.9...3.5),
                                            fps: Double.random(in: 23.2...24.0),
                                            droppedFrameRatio: Double.random(in: 0...0.015),
                                            networkGood: true))
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stop() async {
        statsTask?.cancel()
        statsTask = nil
        statesCont.yield(.stopped)
    }

    func appendVideoPayload(_ payload: any Sendable, timestampSeconds: Double) async {
        // Mock 管线丢弃帧载荷；真实层由 HaishinKit 适配器消费 CMSampleBuffer
    }
}

// MARK: - 假音源路由（激活即生效；HFP 也直接成功，回退演练用真 AudioHub）

actor FakeAudioRouter: AudioRouting {
    nonisolated let states: AsyncStream<AudioRouteState>

    private let statesCont: AsyncStream<AudioRouteState>.Continuation
    private var source: AudioSource = .iphoneMic

    var currentSource: AudioSource { source }

    init() {
        (states, statesCont) = AsyncStream.makeStream(of: AudioRouteState.self)
    }

    @discardableResult
    func activate(_ requested: AudioSource) async -> AudioSource {
        statesCont.yield(.configuring)
        source = requested
        statesCont.yield(.active(requested))
        return requested
    }

    func deactivate() async {
        source = .iphoneMic
        statesCont.yield(.inactive)
    }
}

// MARK: - 组装

struct MockRuntimeComponents {
    let coordinator: SessionCoordinator
    let composer: GlassScreenComposer
    let glasses: MockGlassesSession
    let danmaku: FakeDanmakuConnector
}

enum MockRuntime {

    static func make() -> MockRuntimeComponents {
        let glasses = MockGlassesSession()
        let danmaku = FakeDanmakuConnector()
        let composer = GlassScreenComposer()
        let coordinator = SessionCoordinator(glasses: glasses,
                                             pipeline: FakeStreamPipeline(),
                                             audio: FakeAudioRouter(),
                                             danmaku: danmaku,
                                             composer: composer)
        return MockRuntimeComponents(coordinator: coordinator,
                                     composer: composer,
                                     glasses: glasses,
                                     danmaku: danmaku)
    }

    /// 模拟在线人数漂移（mockup 示例值 1,208 附近浮动）
    static func makeViewerFeed() -> AsyncStream<Int> {
        AsyncStream { continuation in
            let task = Task {
                var count = 1208
                continuation.yield(count)
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    count = max(0, count + Int.random(in: -12...25))
                    continuation.yield(count)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 默认推流目标模板（推流目标屏五张卡的数据源；密钥引用键指向 Keychain）
    static func defaultTargets() -> [RTMPTarget] {
        [
            RTMPTarget(preset: .bilibiliLiveHime, name: "B 站 · 直播姬中转",
                       serverURL: "rtmp://192.168.31.107/live", streamKeyRef: "target.bili.livehime"),
            RTMPTarget(preset: .bilibiliDirect, name: "B 站 · 直接推流",
                       serverURL: "rtmp://live-push.bilivideo.com/live-bvc", streamKeyRef: "target.bili.direct"),
            RTMPTarget(preset: .twitch, name: "Twitch",
                       serverURL: "rtmp://ingest.global-contribute.live-video.net/app", streamKeyRef: "target.twitch"),
            RTMPTarget(preset: .youtube, name: "YouTube Live",
                       serverURL: "rtmp://a.rtmp.youtube.com/live2", streamKeyRef: "target.youtube"),
            RTMPTarget(preset: .custom, name: "自定义 RTMP",
                       serverURL: "rtmp://", streamKeyRef: "target.custom"),
        ]
    }
}
