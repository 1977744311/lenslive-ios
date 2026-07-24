// 画质档 → 编码参数映射。
// StreamEngine 不依赖 GlassesKit，故自定义 StreamQuality；
// 与 GlassesKit.CameraPreset.Quality 同 rawValue（high/medium/low），跨模块经 rawValue 桥接。
import Foundation

public enum StreamQuality: String, Sendable, Codable, CaseIterable {
    case high, medium, low
}

public struct StreamPreset: Sendable, Equatable {
    /// 音频恒为 AAC。HFP 音源实际是 8kHz 单声道（由采集侧决定），编码参数不变，
    /// 重采样在编码管线内完成。
    public static let aacBitrateBps = 128_000
    public static let aacSampleRateHz = 48_000

    public var quality: StreamQuality
    public var width: Int
    public var height: Int
    public var frameRate: Int
    public var videoBitrateBps: Int
    public var audioBitrateBps: Int
    public var audioSampleRateHz: Int

    public var videoBitrateMbps: Double { Double(videoBitrateBps) / 1_000_000 }

    public init(quality: StreamQuality, width: Int, height: Int, frameRate: Int,
                videoBitrateBps: Int,
                audioBitrateBps: Int = StreamPreset.aacBitrateBps,
                audioSampleRateHz: Int = StreamPreset.aacSampleRateHz) {
        self.quality = quality
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.videoBitrateBps = videoBitrateBps
        self.audioBitrateBps = audioBitrateBps
        self.audioSampleRateHz = audioSampleRateHz
    }

    /// DAT 相机竖屏规格（display-capabilities：high 720×1280 / medium 504×896 / low 360×640）。
    public static func preset(for quality: StreamQuality) -> StreamPreset {
        switch quality {
        case .high:
            StreamPreset(quality: .high, width: 720, height: 1280, frameRate: 30,
                         videoBitrateBps: 4_500_000)
        case .medium:
            StreamPreset(quality: .medium, width: 504, height: 896, frameRate: 24,
                         videoBitrateBps: 2_400_000)
        case .low:
            StreamPreset(quality: .low, width: 360, height: 640, frameRate: 24,
                         videoBitrateBps: 1_200_000)
        }
    }
}

extension StreamQuality {
    public var preset: StreamPreset { StreamPreset.preset(for: self) }
}
