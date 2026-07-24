// 把 provider 的多路状态流归并成单一 GlassesHealth 快照 + 变更流。
// 上层（SessionCoordinator / SwiftUI）只需订阅一条流即可拿到眼镜全貌。
import Foundation

public struct GlassesHealth: Sendable, Equatable {
    public var session: GlassesSessionState
    public var display: DisplayState
    public var camera: CameraStreamState
    public var thermal: ThermalLevel

    public init(session: GlassesSessionState = .idle,
                display: DisplayState = .stopped,
                camera: CameraStreamState = .stopped,
                thermal: ThermalLevel = .normal) {
        self.session = session
        self.display = display
        self.camera = camera
        self.thermal = thermal
    }
}

public actor GlassesSessionTracker {

    private let provider: any GlassesSessionProviding
    private let bus = StreamBroadcaster<GlassesHealth>(replaysLatest: true)
    private var health = GlassesHealth()
    private var consumers: [Task<Void, Never>] = []

    public init(provider: any GlassesSessionProviding) {
        self.provider = provider
    }

    /// 归并后的健康快照变更流（多订阅；新订阅者立即收到最近一次快照）
    public nonisolated var updates: AsyncStream<GlassesHealth> { bus.subscribe() }

    public var current: GlassesHealth { health }

    public func start() {
        guard consumers.isEmpty else { return }
        bus.send(health)   // 基线快照

        let sessionStates = provider.sessionStates
        let displayStates = provider.displayStates
        let cameraStates = provider.cameraStates
        let thermalLevels = provider.thermal

        consumers = [
            Task { [weak self] in
                for await state in sessionStates { await self?.mutate { $0.session = state } }
            },
            Task { [weak self] in
                for await state in displayStates { await self?.mutate { $0.display = state } }
            },
            Task { [weak self] in
                for await state in cameraStates { await self?.mutate { $0.camera = state } }
            },
            Task { [weak self] in
                for await level in thermalLevels { await self?.mutate { $0.thermal = level } }
            },
        ]
    }

    public func stop() {
        for task in consumers { task.cancel() }
        consumers = []
    }

    private func mutate(_ change: (inout GlassesHealth) -> Void) {
        var next = health
        change(&next)
        guard next != health else { return }
        health = next
        bus.send(next)
    }
}
