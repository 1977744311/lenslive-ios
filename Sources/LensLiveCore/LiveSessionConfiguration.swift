// 开播配置 —— SessionCoordinator.startLive 的唯一入参。
// 串流密钥由 App 层从 Keychain 解出后注入（Core 不接触钥匙串）。
import Foundation
import AudioHub
import GlassesKit
import StreamEngine

public struct LiveSessionConfiguration: Sendable, Equatable {
    // 推流
    public var target: RTMPTarget
    public var streamKey: String
    public var cameraPreset: CameraPreset

    // 音源
    public var audioSource: AudioSource

    // 弹幕（false = 纯推流状态屏场景，danmaku 不计入就绪位图）
    public var danmakuEnabled: Bool

    // 眼镜上屏参数（PRD F6：条数默认 6 / 节流默认 1s / 驻留默认 8s）
    public var displayLineCount: Int
    public var displayThrottle: TimeInterval
    public var highValueDwell: TimeInterval
    public var blockEnterMessages: Bool

    // 故障策略
    public var autoThermalDowngrade: Bool

    // UI 消费缓冲上限
    public var danmakuBufferLimit: Int
    public var noticeLimit: Int

    public init(target: RTMPTarget,
                streamKey: String,
                cameraPreset: CameraPreset = .default,
                audioSource: AudioSource = .iphoneMic,
                danmakuEnabled: Bool = true,
                displayLineCount: Int = 6,
                displayThrottle: TimeInterval = 1,
                highValueDwell: TimeInterval = 8,
                blockEnterMessages: Bool = true,
                autoThermalDowngrade: Bool = true,
                danmakuBufferLimit: Int = 120,
                noticeLimit: Int = 20) {
        self.target = target
        self.streamKey = streamKey
        self.cameraPreset = cameraPreset
        self.audioSource = audioSource
        self.danmakuEnabled = danmakuEnabled
        self.displayLineCount = displayLineCount
        self.displayThrottle = displayThrottle
        self.highValueDwell = highValueDwell
        self.blockEnterMessages = blockEnterMessages
        self.autoThermalDowngrade = autoThermalDowngrade
        self.danmakuBufferLimit = danmakuBufferLimit
        self.noticeLimit = noticeLimit
    }
}
