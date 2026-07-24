// RTMP 推流目标校验 + 平台预设工厂。
// 开播政策背景（research-live-danmaku.md §8.3）：B 站 <5000 粉拿不到直推地址，
// 走直播姬"第三方推流"本地中转；抖音等无个人推流码平台一律走 custom 手填。
import Foundation

public enum RTMPTargetValidator {
    public static let allowedSchemes: Set<String> = ["rtmp", "rtmps"]

    /// 校验顺序：scheme（必须 rtmp/rtmps）→ host 非空 → streamKey 非空。
    /// 无法解析为 URL 的输入按 invalidScheme 处理。
    public static func validate(serverURL: String, streamKey: String) throws(RTMPTargetValidationError) {
        let trimmedURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmedURL),
              let scheme = components.scheme?.lowercased(),
              allowedSchemes.contains(scheme) else {
            throw .invalidScheme
        }
        guard let host = components.host, !host.isEmpty else {
            throw .emptyHost
        }
        guard !streamKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw .emptyStreamKey
        }
    }

    /// 便捷重载：streamKey 从 Keychain 取出后与 target 一并校验。
    public static func validate(_ target: RTMPTarget, streamKey: String) throws(RTMPTargetValidationError) {
        try validate(serverURL: target.serverURL, streamKey: streamKey)
    }
}

// MARK: - 预设工厂

extension RTMPTarget {
    /// B 站直推（直播中心可见 RTMP 地址，要求 ≥5000 粉）。
    public static func bilibiliDirect(streamKeyRef: String) -> RTMPTarget {
        RTMPTarget(preset: .bilibiliDirect,
                   name: "B 站直推",
                   serverURL: "rtmp://live-push.bilivideo.com/live-bvc/",
                   streamKeyRef: streamKeyRef)
    }

    /// B 站直播姬本地中转（直播姬"第三方推流"模式在局域网起本地 RTMP server）。
    /// serverURL 为占位模板，实际 IP/端口/应用名以直播姬界面显示为准，由用户在设置页改写。
    public static func bilibiliLiveHime(serverURL: String = "rtmp://192.168.1.100:1935/live",
                                        streamKeyRef: String) -> RTMPTarget {
        RTMPTarget(preset: .bilibiliLiveHime,
                   name: "B 站直播姬中转",
                   serverURL: serverURL,
                   streamKeyRef: streamKeyRef)
    }

    public static func twitch(streamKeyRef: String) -> RTMPTarget {
        RTMPTarget(preset: .twitch,
                   name: "Twitch",
                   serverURL: "rtmp://live.twitch.tv/app/",
                   streamKeyRef: streamKeyRef)
    }

    public static func youtube(streamKeyRef: String) -> RTMPTarget {
        RTMPTarget(preset: .youtube,
                   name: "YouTube",
                   serverURL: "rtmp://a.rtmp.youtube.com/live2/",
                   streamKeyRef: streamKeyRef)
    }

    /// 抖音（PC 直播伴侣临时码）等自定义目标。
    public static func custom(name: String, serverURL: String, streamKeyRef: String) -> RTMPTarget {
        RTMPTarget(preset: .custom,
                   name: name,
                   serverURL: serverURL,
                   streamKeyRef: streamKeyRef)
    }
}
