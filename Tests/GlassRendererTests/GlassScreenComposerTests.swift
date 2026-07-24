import Foundation
import Testing
import GlassRenderer
import GlassesKit
import DanmakuCore

// MARK: - 固定输入（对齐 mockups/glass-frames.jsx 示例数据）

enum ComposerFixtures {
    static let composer = GlassScreenComposer()

    /// G1/G2 顶部状态：23:41 · 在线 1.2k
    static let liveStatus = LiveStatusSummary(
        elapsed: 1421, viewers: 1200, bitrateMbps: 2.4, fps: 24, networkGood: true, thermal: .normal)

    /// G3 状态屏：01:07:23 · 无观众数
    static let streamOnlyStatus = LiveStatusSummary(
        elapsed: 4043, viewers: nil, bitrateMbps: 2.4, fps: 24, networkGood: true, thermal: .normal)

    static let danmakuEvents: [DanmakuEvent] = [
        chatEvent(id: "e1", user: "骑行的老王", text: "这条路秋天来更好看"),
        chatEvent(id: "e2", user: "momo", text: "主播今天走了多少公里了？"),
        chatEvent(id: "e3", user: "不吃香菜", text: "左边那家店上次你推荐过！"),
        chatEvent(id: "e4", user: "Nova_7", text: "声音很清楚，继续继续"),
        chatEvent(id: "e5", user: "阿云", text: "问一下机位是眼镜拍的吗，太稳了"),
    ]

    static let superChat = superChatEvent(
        id: "sc1", user: "山高月小", text: "能不能讲讲这副眼镜直播的延迟大概多少？很想入", value: 50)

    static let underlying: [DanmakuEvent] = [
        chatEvent(id: "u1", user: "Nova_7", text: "前面 SC 问得好"),
        chatEvent(id: "u2", user: "不吃香菜", text: "蹲一个延迟实测"),
    ]
}

// MARK: - 结构断言

@Suite("GlassScreenComposer 结构")
struct GlassScreenComposerStructureTests {

    @Test("弹幕主屏：状态行 + ≤6 条弹幕 + 三 tap 区")
    func danmakuScreenStructure() {
        let screen = ComposerFixtures.composer.danmakuScreen(
            events: ComposerFixtures.danmakuEvents, mode: .all, status: ComposerFixtures.liveStatus)

        let texts = collectTexts(screen)
        #expect(texts.first?.text == "LIVE")
        #expect(texts.contains { $0.text == "23:41" && $0.style == .meta && $0.color == .secondary })
        #expect(texts.contains { $0.text == "在线 1.2k" })
        #expect(texts.contains { $0.text == "全部弹幕" })
        // 5 条弹幕：昵称 meta+secondary、内容 body+primary
        #expect(texts.filter { $0.style == .body && $0.color == .primary }.count == 5)
        #expect(texts.contains { $0.text == "骑行的老王" && $0.style == .meta && $0.color == .secondary })

        let buttons = collectButtons(screen)
        #expect(buttons.map(\.actionID) == ["pause", "cycleFilter", "markRead"])
        #expect(buttons.map(\.label) == ["暂停", "过滤 · 全部", "已读"])
        #expect(buttons[1].style == .primary)
    }

    @Test("弹幕超过 6 条只保留最近 6 条")
    func danmakuScreenCapsAtSixEntries() {
        let events = (1...8).map { chatEvent(id: "e\($0)", user: "用户\($0)", text: "内容\($0)") }
        let screen = ComposerFixtures.composer.danmakuScreen(
            events: events, mode: .all, status: ComposerFixtures.liveStatus)

        let bodies = collectTexts(screen).filter { $0.style == .body && $0.color == .primary }
        #expect(bodies.count == 6)
        #expect(bodies.first?.text == "内容3")   // 最早两条被裁掉
        #expect(bodies.last?.text == "内容8")
    }

    @Test("弹幕内容超 60 字符截断为 59+省略号")
    func danmakuTextTruncatedAt60() {
        let long = String(repeating: "长", count: 80)
        let screen = ComposerFixtures.composer.danmakuScreen(
            events: [chatEvent(id: "e1", user: "u", text: long)], mode: .all,
            status: ComposerFixtures.liveStatus)

        let body = collectTexts(screen).first { $0.style == .body && $0.color == .primary }
        #expect(body?.text.count == 60)
        #expect(body?.text.hasSuffix("…") == true)
        #expect(body?.text.hasPrefix(String(repeating: "长", count: 59)) == true)
    }

    @Test("高价值卡：金卡置顶 + 压缩 2 条弹幕 + tap 区档位联动")
    func highValueCardStructure() {
        let screen = ComposerFixtures.composer.highValueCard(
            event: ComposerFixtures.superChat, remaining: 8,
            underlying: ComposerFixtures.underlying, mode: .highValueOnly,
            status: ComposerFixtures.liveStatus)

        #expect(collectIcons(screen) == [.checkmarkCircle, .star])   // 状态行 + SC 卡
        let texts = collectTexts(screen)
        #expect(texts.contains { $0.text == "SC ¥50" && $0.style == .heading && $0.color == .primary })
        #expect(texts.contains { $0.text == "驻留 8s" && $0.style == .meta })
        #expect(texts.contains { $0.text == "山高月小" })
        #expect(texts.contains { $0.text == "仅 SC·礼物" })
        // 卡片留言 + 2 条压缩弹幕 = 3 个 body
        #expect(texts.filter { $0.style == .body && $0.color == .primary }.count == 3)

        let buttons = collectButtons(screen)
        #expect(buttons.map(\.label) == ["暂停", "过滤 · SC", "已读"])
        #expect(buttons.map(\.actionID) == ["pause", "cycleFilter", "markRead"])
    }

    @Test("礼物事件金卡用 gift 图标与礼物文案")
    func giftCardUsesGiftIcon() {
        let gift = DanmakuEvent(id: "g1", platform: .bilibili, kind: .gift, user: "送礼人",
                                text: "×1 舰长体验卡", value: 9.9,
                                timestamp: Date(timeIntervalSince1970: 0))
        let screen = ComposerFixtures.composer.highValueCard(
            event: gift, remaining: 8, underlying: [], mode: .all,
            status: ComposerFixtures.liveStatus)

        #expect(collectIcons(screen).contains(.gift))
        #expect(collectTexts(screen).contains { $0.text == "礼物 ¥9.9" && $0.style == .heading })
    }

    @Test("状态屏：大字时长 + 四格 + 提示行，无观众数")
    func statusScreenStructure() {
        let screen = ComposerFixtures.composer.statusScreen(status: ComposerFixtures.streamOnlyStatus)

        let texts = collectTexts(screen)
        #expect(texts.contains { $0.text == "01:07:23" && $0.style == .heading && $0.color == .primary })
        #expect(texts.contains { $0.text == "已直播" })
        for pair in [("码率", "2.4 Mbps"), ("帧率", "24 fps"), ("网络", "良好"), ("眼镜温度", "正常")] {
            #expect(texts.contains { $0.text == pair.0 && $0.style == .meta })
            #expect(texts.contains { $0.text == pair.1 && $0.style == .body })
        }
        #expect(texts.contains { $0.text == "当前平台无弹幕通道 · 互动请看手机" })
        #expect(!texts.contains { $0.text.hasPrefix("在线") })
        #expect(collectButtons(screen).isEmpty)
    }

    @Test("告警屏：warning 图标 + 降档说明 + 两按钮")
    func alertScreenStructure() {
        let screen = ComposerFixtures.composer.alertScreen(
            fault: .thermal(.hot), degradedPreset: CameraPreset(quality: .medium, frameRate: 24))

        #expect(collectIcons(screen).contains(.warning))
        let texts = collectTexts(screen)
        #expect(texts.contains { $0.text == "眼镜温度偏高" && $0.style == .heading })
        #expect(texts.contains { $0.text == "画质已自动降为 504×896 · 24fps" && $0.style == .body && $0.color == .secondary })
        #expect(texts.contains { $0.text == "直播未中断，建议阴凉处继续" })

        let buttons = collectButtons(screen)
        #expect(buttons.map(\.actionID) == ["ackAlert", "endLive"])
        #expect(buttons.map(\.label) == ["知道了", "结束直播"])
        #expect(buttons[0].style == .primary)
    }

    @Test("无降档信息时告警屏不出现降档行")
    func alertScreenWithoutDegradedPreset() {
        let screen = ComposerFixtures.composer.alertScreen(fault: .batteryCritical, degradedPreset: nil)
        let texts = collectTexts(screen)
        #expect(texts.contains { $0.text == "眼镜电量严重不足" })
        #expect(!texts.contains { $0.text.hasPrefix("画质已自动降为") })
    }

    @Test("过滤档位驱动状态行与按钮文案")
    func filterModeDrivesLabels() {
        for (mode, right, button) in [
            (DanmakuFilterMode.all, "全部弹幕", "过滤 · 全部"),
            (.highValueOnly, "仅 SC·礼物", "过滤 · SC"),
            (.paused, "已暂停", "过滤 · 暂停"),
        ] {
            let screen = ComposerFixtures.composer.danmakuScreen(
                events: [], mode: mode, status: ComposerFixtures.liveStatus)
            let texts = collectTexts(screen)
            #expect(texts.contains { $0.text == right })
            #expect(collectButtons(screen).map(\.label).contains(button))
        }
    }
}
