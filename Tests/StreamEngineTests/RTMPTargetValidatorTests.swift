import Foundation
import Testing
@testable import StreamEngine

@Suite("RTMPTargetValidator")
struct RTMPTargetValidatorTests {
    // MARK: - 通过路径

    @Test func validRTMPPasses() throws {
        try RTMPTargetValidator.validate(serverURL: "rtmp://live-push.bilivideo.com/live-bvc/",
                                         streamKey: "k?streamname=x")
    }

    @Test func validRTMPSPassesCaseInsensitively() throws {
        try RTMPTargetValidator.validate(serverURL: "RTMPS://Live.Example.Com:443/app",
                                         streamKey: "key")
    }

    @Test func surroundingWhitespaceIsTolerated() throws {
        try RTMPTargetValidator.validate(serverURL: "  rtmp://a.rtmp.youtube.com/live2/  ",
                                         streamKey: "key")
    }

    // MARK: - 失败分支

    @Test(arguments: [
        "http://live.example.com/app",   // 非 rtmp 协议
        "srt://live.example.com:9000",   // 非 rtmp 协议
        "live.example.com/app",          // 无 scheme
        "",                              // 空串
        "not a url at all",              // 不可解析
    ])
    func invalidSchemeIsRejected(serverURL: String) {
        #expect(throws: RTMPTargetValidationError.invalidScheme) {
            try RTMPTargetValidator.validate(serverURL: serverURL, streamKey: "key")
        }
    }

    @Test(arguments: ["rtmp://", "rtmp:///live", "rtmps://:1935/app"])
    func emptyHostIsRejected(serverURL: String) {
        #expect(throws: RTMPTargetValidationError.emptyHost) {
            try RTMPTargetValidator.validate(serverURL: serverURL, streamKey: "key")
        }
    }

    @Test(arguments: ["", "   ", "\n\t"])
    func emptyStreamKeyIsRejected(streamKey: String) {
        #expect(throws: RTMPTargetValidationError.emptyStreamKey) {
            try RTMPTargetValidator.validate(serverURL: "rtmp://live.twitch.tv/app/",
                                             streamKey: streamKey)
        }
    }

    @Test func schemeIsCheckedBeforeHostAndKey() {
        // 多重缺陷时按 scheme → host → key 顺序报第一个
        #expect(throws: RTMPTargetValidationError.invalidScheme) {
            try RTMPTargetValidator.validate(serverURL: "http://", streamKey: "")
        }
    }

    @Test func targetOverloadValidates() {
        let target = RTMPTarget.custom(name: "抖音伴侣", serverURL: "rtmp://push.example.com/live",
                                       streamKeyRef: "ref")
        #expect(throws: RTMPTargetValidationError.emptyStreamKey) {
            try RTMPTargetValidator.validate(target, streamKey: "")
        }
    }

    // MARK: - 预设工厂

    @Test func bilibiliDirectFactory() throws {
        let target = RTMPTarget.bilibiliDirect(streamKeyRef: "kc-bili")
        #expect(target.preset == .bilibiliDirect)
        #expect(target.serverURL == "rtmp://live-push.bilivideo.com/live-bvc/")
        #expect(target.streamKeyRef == "kc-bili")
        try RTMPTargetValidator.validate(target, streamKey: "dummy")
    }

    @Test func bilibiliLiveHimeFactoryUsesLANPlaceholder() throws {
        let target = RTMPTarget.bilibiliLiveHime(streamKeyRef: "kc-hime")
        #expect(target.preset == .bilibiliLiveHime)
        #expect(target.serverURL == "rtmp://192.168.1.100:1935/live")
        // 占位地址可被用户改写
        let custom = RTMPTarget.bilibiliLiveHime(serverURL: "rtmp://10.0.0.8:1936/x", streamKeyRef: "r")
        #expect(custom.serverURL == "rtmp://10.0.0.8:1936/x")
        try RTMPTargetValidator.validate(target, streamKey: "dummy")
    }

    @Test func twitchFactory() throws {
        let target = RTMPTarget.twitch(streamKeyRef: "kc-twitch")
        #expect(target.preset == .twitch)
        #expect(target.serverURL == "rtmp://live.twitch.tv/app/")
        try RTMPTargetValidator.validate(target, streamKey: "dummy")
    }

    @Test func youtubeFactory() throws {
        let target = RTMPTarget.youtube(streamKeyRef: "kc-yt")
        #expect(target.preset == .youtube)
        #expect(target.serverURL == "rtmp://a.rtmp.youtube.com/live2/")
        try RTMPTargetValidator.validate(target, streamKey: "dummy")
    }

    @Test func customFactory() {
        let target = RTMPTarget.custom(name: "本地 SRS", serverURL: "rtmp://127.0.0.1/live",
                                       streamKeyRef: "kc-srs")
        #expect(target.preset == .custom)
        #expect(target.name == "本地 SRS")
        #expect(target.serverURL == "rtmp://127.0.0.1/live")
    }
}
