// AudioPortControlling 的 AVAudioSession/AVAudioEngine 真实实现（App target 编译）。
//
// 官方顺序约束（display-capabilities.md 设备音频节 / research-live-danmaku.md §8.2）：
//   1. DAT addStream 先挂载相机能力（尚未 start）
//   2. 配置 HFP 路由：setCategory(.playAndRecord, .allowBluetoothHFP) → setActive
//      → setPreferredInput(bluetoothHFP)
//   3. 等待路由稳定（官方样例 2s；等待由 AudioRouteController 的 settling 状态驱动，
//      本适配器不自行 sleep）
//   4. verifyRoute 用 currentRoute 校验输入确已切到 bluetoothHFP
//   5. 之后才允许 stream.start()——顺序颠倒会静默失败
//
// 音质预期（display-capabilities.md）：HFP 采音 8kHz 单声道 + 波束成形（只保佩戴者人声），
// 激活期间眼镜扬声器同降 8kHz 电话音质，属协议行为非缺陷。
#if canImport(AVFoundation) && os(iOS)
import AVFoundation
import AudioHub

public enum AudioPortError: Error, Sendable {
    /// 可用输入里没有蓝牙 HFP 端口（眼镜未连接或系统未暴露 HFP profile）
    case hfpInputNotFound
}

public final class HFPAudioPortAdapter: AudioPortControlling, @unchecked Sendable {
    private let session = AVAudioSession.sharedInstance()
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var tapInstalled = false
    private var handler: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?

    public init() {}

    /// M0 留接口：PCM 采集回调，交给推流管线做 AAC 编码
    /// （典型接线：{ buffer, when in Task { await haishinKitAdapter.appendAudioBuffer(buffer, when: when) } }）。
    public func setPCMHandler(_ handler: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    // MARK: - AudioPortControlling

    public func configureRoute(for source: AudioSource) async throws {
        switch source {
        case .glassesHFP:
            // .allowBluetoothHFP 是 iOS 26 SDK 对旧 .allowBluetooth 的更名（同为 HFP 语义）
            try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP])
            try session.setActive(true)
            guard let hfpInput = session.availableInputs?.first(where: { $0.portType == .bluetoothHFP }) else {
                throw AudioPortError.hfpInputNotFound
            }
            try session.setPreferredInput(hfpInput)
            try startEngineTap()

        case .iphoneMic:
            try session.setCategory(.playAndRecord, mode: .default, options: [])
            try session.setActive(true)
            if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try session.setPreferredInput(builtIn)
            }
            try startEngineTap()

        case .muted:
            break // AudioRouteController 不会以 muted 调用（静音无系统路由）
        }
    }

    public func verifyRoute(for source: AudioSource) async -> Bool {
        switch source {
        case .glassesHFP:
            return session.currentRoute.inputs.contains { $0.portType == .bluetoothHFP }
        case .iphoneMic:
            return session.currentRoute.inputs.contains { $0.portType == .builtInMic }
        case .muted:
            return true
        }
    }

    public func teardown() async {
        lock.lock()
        let hadTap = tapInstalled
        tapInstalled = false
        lock.unlock()
        if hadTap {
            engine.inputNode.removeTap(onBus: 0)
        }
        engine.stop()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - 采集

    private func startEngineTap() throws {
        lock.lock()
        let alreadyInstalled = tapInstalled
        tapInstalled = true
        lock.unlock()
        guard !alreadyInstalled else { return }

        let input = engine.inputNode
        // HFP 路由下 inputFormat 为 8kHz 单声道；用硬件原生格式取流，
        // 重采样到 48kHz AAC 由编码管线负责（StreamPreset 编码参数不因源而变）
        let format = input.inputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, when in
            guard let self else { return }
            self.lock.lock()
            let handler = self.handler
            self.lock.unlock()
            handler?(buffer, when)
        }
        engine.prepare()
        try engine.start()
    }
}
#endif
