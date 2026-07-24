// StreamPipelining 的 HaishinKit 2.2 真实实现（App target 编译；库层 swift build 不含本文件）。
//
// 管线（research-live-danmaku.md §8.1）：
//   DAT 相机帧（VideoCodec.raw → CMSampleBuffer）
//     → MediaMixer(captureSessionMode: .manual) + videoMixerSettings.mode = .passthrough
//     → RTMPStream（VideoToolbox H.264 + AAC 编码）
//     → RTMPConnection.connect(serverURL) + RTMPStream.publish(streamKey)
//
// HaishinKit 2.1 起 RTMP 相关类型拆分到 RTMPHaishinKit 模块（project.yml 已同时挂两个 product）。
#if canImport(HaishinKit) && canImport(RTMPHaishinKit)
import AVFoundation
import CoreMedia
import Foundation
import HaishinKit
import RTMPHaishinKit
import StreamEngine

public actor HaishinKitPipelineAdapter: StreamPipelining {
    public nonisolated var states: AsyncStream<StreamPipelineState> { stateChannel.stream() }
    public nonisolated var stats: AsyncStream<StreamStats> { statsChannel.stream() }

    private let preset: StreamPreset
    /// manual 模式：不创建 AVCaptureSession，帧源完全由 appendVideoPayload 外部驱动。
    private let mixer: MediaMixer
    private let stateChannel = AsyncBroadcast<StreamPipelineState>()
    private let statsChannel = AsyncBroadcast<StreamStats>()

    private var connection: RTMPConnection?
    private var stream: RTMPStream?
    private var statusTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    private var aggregator: StatsAggregator
    private var lastFrameTimestamp: Double = 0
    private var mixerConfigured = false
    private var phase: StreamPipelineState = .idle

    public init(preset: StreamPreset) {
        self.preset = preset
        self.mixer = MediaMixer(captureSessionMode: .manual)
        self.aggregator = StatsAggregator(targetBitrateMbps: preset.videoBitrateMbps)
    }

    // MARK: - StreamPipelining

    public func start(target: RTMPTarget, streamKey: String) async throws {
        try RTMPTargetValidator.validate(serverURL: target.serverURL, streamKey: streamKey)
        emit(.connecting)

        let connection = RTMPConnection()
        let stream = RTMPStream(connection: connection)
        self.connection = connection
        self.stream = stream

        if !mixerConfigured {
            mixerConfigured = true
            // passthrough：相机帧不经 offscreen 合成直接进编码器（帧路径 <5ms 预算的关键）
            var mixSettings = await mixer.videoMixerSettings
            mixSettings.mode = .passthrough
            await mixer.setVideoMixerSettings(mixSettings)
            // 输出帧率与预设对齐（DAT 相机帧率由 GlassesKit 侧的 CameraPreset 决定）
            try? await mixer.setFrameRate(Float64(preset.frameRate))
            // 2.1+ 必须显式启动（manual 模式下不会隐式开始）
            await mixer.startRunning()
        }
        await mixer.addOutput(stream)

        // H.264 编码参数（RTMP 生态兼容性优先，不用 HEVC）
        var video = VideoCodecSettings()
        video.videoSize = CGSize(width: CGFloat(preset.width), height: CGFloat(preset.height))
        video.bitRate = preset.videoBitrateBps
        video.maxKeyFrameIntervalDuration = 2
        await stream.setVideoSettings(video)

        // AAC 128kbps；HFP 源实际 8kHz 单声道由采集侧决定，编码参数不变（重采样在编码器内完成）
        var audio = AudioCodecSettings()
        audio.bitRate = preset.audioBitrateBps
        await stream.setAudioSettings(audio)

        // 断连观察：publish 成功后服务端断开不会以 throw 形式出现，
        // 只能从 connection.status 收 NetConnection.Connect.Closed/Failed（HaishinKit #1584）
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            for await status in await connection.status {
                await self?.handleRTMPStatus(status)
            }
        }

        do {
            _ = try await connection.connect(target.serverURL)
            _ = try await stream.publish(streamKey)
        } catch {
            emit(.failed(reason: "RTMP 连接/发布失败: \(error)"))
            throw error
        }
        emit(.streaming)
        startStatsSampling()
    }

    public func stop() async {
        statusTask?.cancel()
        statusTask = nil
        statsTask?.cancel()
        statsTask = nil
        if let stream {
            _ = try? await stream.close()
            await mixer.removeOutput(stream)
        }
        if let connection {
            try? await connection.close()
        }
        stream = nil
        connection = nil
        aggregator.reset()
        emit(.stopped)
    }

    /// GlassesKit 相机帧入口：载荷强转 CMSampleBuffer 后透传 mixer（manual+passthrough）。
    public func appendVideoPayload(_ payload: any Sendable, timestampSeconds: Double) async {
        lastFrameTimestamp = timestampSeconds
        guard let sampleBuffer = payload as? CMSampleBuffer else {
            aggregator.recordDropped(at: timestampSeconds)
            return
        }
        aggregator.recordFrame(bytes: CMSampleBufferGetTotalSampleSize(sampleBuffer),
                               at: timestampSeconds)
        await mixer.append(sampleBuffer)
    }

    // MARK: - 音频接入（M0 留接口）

    /// AudioHub 采集回调接入点：HFPAudioPortAdapter.pcmHandler → 此处 → AAC 编码。
    public func appendAudioBuffer(_ buffer: AVAudioPCMBuffer, when: AVAudioTime) async {
        await mixer.append(buffer, when: when, track: 0)
    }

    // MARK: - 内部

    private func handleRTMPStatus(_ status: RTMPStatus) {
        switch status.code {
        case RTMPConnection.Code.connectClosed.rawValue,
             RTMPConnection.Code.connectFailed.rawValue:
            // 上报断流；退避重连由 StreamSessionController 统一驱动
            emit(.failed(reason: "RTMP 连接中断: \(status.code)"))
        default:
            break
        }
    }

    /// 1Hz 上报统计。
    /// 注意：recordFrame 记录的是编码前载荷大小，bitrateMbps 是上行体量的近似值；
    /// 精确网络码率需接 HaishinKit 流量计数（见遗留 TODO），networkGood 判定 M1 校准。
    private func startStatsSampling() {
        statsTask?.cancel()
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                await self.publishStats()
            }
        }
    }

    private func publishStats() {
        statsChannel.yield(aggregator.snapshot(at: lastFrameTimestamp))
    }

    private func emit(_ next: StreamPipelineState) {
        guard next != phase else { return }
        phase = next
        stateChannel.yield(next)
    }
}
#endif
