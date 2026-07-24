import Testing
@testable import StreamEngine

@Suite("StreamPresets")
struct StreamPresetsTests {
    @Test func highMapsTo720p30() {
        let preset = StreamQuality.high.preset
        #expect(preset.width == 720)
        #expect(preset.height == 1280)
        #expect(preset.frameRate == 30)
        #expect(preset.videoBitrateBps == 4_500_000)
        #expect(preset.videoBitrateMbps == 4.5)
    }

    @Test func mediumMapsTo504p24() {
        let preset = StreamQuality.medium.preset
        #expect(preset.width == 504)
        #expect(preset.height == 896)
        #expect(preset.frameRate == 24)
        #expect(preset.videoBitrateBps == 2_400_000)
        #expect(preset.videoBitrateMbps == 2.4)
    }

    @Test func lowMapsTo360p24() {
        let preset = StreamQuality.low.preset
        #expect(preset.width == 360)
        #expect(preset.height == 640)
        #expect(preset.frameRate == 24)
        #expect(preset.videoBitrateBps == 1_200_000)
        #expect(preset.videoBitrateMbps == 1.2)
    }

    /// 音频编码参数与画质档解耦：恒为 AAC 128kbps / 48kHz（HFP 源实际 8kHz 由采集侧决定）
    @Test(arguments: StreamQuality.allCases)
    func audioSettingsAreConstant(quality: StreamQuality) {
        let preset = quality.preset
        #expect(preset.audioBitrateBps == 128_000)
        #expect(preset.audioSampleRateHz == 48_000)
    }

    /// 与 GlassesKit.CameraPreset.Quality 经 rawValue 桥接
    @Test func rawValueBridgesFromCameraQuality() {
        #expect(StreamQuality(rawValue: "high") == .high)
        #expect(StreamQuality(rawValue: "medium") == .medium)
        #expect(StreamQuality(rawValue: "low") == .low)
        #expect(StreamQuality(rawValue: "ultra") == nil)
    }
}
