// 四屏 canonicalJSON 快照 —— 锁定序列化稳定性（键排序）与信息结构。
// 期望常量由实际输出回填；任何布局/文案/格式化变更都会在此显式暴露。
import Foundation
import Testing
import GlassRenderer
import GlassesKit

@Suite("GlassScreenComposer canonicalJSON 快照")
struct GlassScreenSnapshotTests {

    @Test("danmakuScreen 快照")
    func danmakuScreenSnapshot() throws {
        let screen = ComposerFixtures.composer.danmakuScreen(
            events: ComposerFixtures.danmakuEvents, mode: .all, status: ComposerFixtures.liveStatus)
        let expected = #"{"flexBox":{"_0":{"alignment":"start","crossAlignment":"stretch","direction":"column","gap":12,"padding":20},"children":[{"flexBox":{"_0":{"alignment":"start","crossAlignment":"center","direction":"row","gap":12,"padding":0},"children":[{"icon":{"_0":"checkmarkCircle"}},{"text":{"_0":"LIVE","color":"primary","style":"meta"}},{"text":{"_0":"23:41","color":"secondary","style":"meta"}},{"text":{"_0":"在线 1.2k","color":"secondary","style":"meta"}},{"text":{"_0":"全部弹幕","color":"secondary","style":"meta"}}]}},{"flexBox":{"_0":{"alignment":"end","crossAlignment":"stretch","direction":"column","gap":10,"padding":0},"children":[{"flexBox":{"_0":{"alignment":"start","crossAlignment":"start","direction":"column","gap":3,"padding":0},"children":[{"text":{"_0":"骑行的老王","color":"secondary","style":"meta"}},{"text":{"_0":"这条路秋天来更好看","color":"primary","style":"body"}}]}},{"flexBox":{"_0":{"alignment":"start","crossAlignment":"start","direction":"column","gap":3,"padding":0},"children":[{"text":{"_0":"momo","color":"secondary","style":"meta"}},{"text":{"_0":"主播今天走了多少公里了？","color":"primary","style":"body"}}]}},{"flexBox":{"_0":{"alignment":"start","crossAlignment":"start","direction":"column","gap":3,"padding":0},"children":[{"text":{"_0":"不吃香菜","color":"secondary","style":"meta"}},{"text":{"_0":"左边那家店上次你推荐过！","color":"primary","style":"body"}}]}},{"flexBox":{"_0":{"alignment":"start","crossAlignment":"start","direction":"column","gap":3,"padding":0},"children":[{"text":{"_0":"Nova_7","color":"secondary","style":"meta"}},{"text":{"_0":"声音很清楚，继续继续","color":"primary","style":"body"}}]}},{"flexBox":{"_0":{"alignment":"start","crossAlignment":"start","direction":"column","gap":3,"padding":0},"children":[{"text":{"_0":"阿云","color":"secondary","style":"meta"}},{"text":{"_0":"问一下机位是眼镜拍的吗，太稳了","color":"primary","style":"body"}}]}}]}},{"flexBox":{"_0":{"alignment":"start","crossAlignment":"start","direction":"row","gap":12,"padding":0},"children":[{"button":{"actionID":"pause","label":"暂停","style":"secondary"}},{"button":{"actionID":"cycleFilter","label":"过滤 · 全部","style":"primary"}},{"button":{"actionID":"markRead","label":"已读","style":"secondary"}}]}}]}}"#
        #expect(try GlassNodeEncoder.canonicalJSON(screen) == expected)
    }

    @Test("highValueCard 快照")
    func highValueCardSnapshot() throws {
        let screen = ComposerFixtures.composer.highValueCard(
            event: ComposerFixtures.superChat, remaining: 8,
            underlying: ComposerFixtures.underlying, mode: .highValueOnly,
            status: ComposerFixtures.liveStatus)
        let expected = #"{"flexBox":{"_0":{"alignment":"start","crossAlignment":"stretch","direction":"column","gap":12,"padding":20},"children":[{"flexBox":{"_0":{"alignment":"start","crossAlignment":"center","direction":"row","gap":12,"padding":0},"children":[{"icon":{"_0":"checkmarkCircle"}},{"text":{"_0":"LIVE","color":"primary","style":"meta"}},{"text":{"_0":"23:41","color":"secondary","style":"meta"}},{"text":{"_0":"在线 1.2k","color":"secondary","style":"meta"}},{"text":{"_0":"仅 SC·礼物","color":"secondary","style":"meta"}}]}},{"flexBox":{"_0":{"alignment":"start","crossAlignment":"start","direction":"column","gap":10,"padding":20},"children":[{"flexBox":{"_0":{"alignment":"start","crossAlignment":"center","direction":"row","gap":10,"padding":0},"children":[{"icon":{"_0":"star"}},{"text":{"_0":"SC ¥50","color":"primary","style":"heading"}},{"text":{"_0":"驻留 8s","color":"secondary","style":"meta"}}]}},{"text":{"_0":"山高月小","color":"secondary","style":"meta"}},{"text":{"_0":"能不能讲讲这副眼镜直播的延迟大概多少？很想入","color":"primary","style":"body"}}]}},{"flexBox":{"_0":{"alignment":"end","crossAlignment":"stretch","direction":"column","gap":10,"padding":0},"children":[{"flexBox":{"_0":{"alignment":"start","crossAlignment":"start","direction":"column","gap":3,"padding":0},"children":[{"text":{"_0":"Nova_7","color":"secondary","style":"meta"}},{"text":{"_0":"前面 SC 问得好","color":"primary","style":"body"}}]}},{"flexBox":{"_0":{"alignment":"start","crossAlignment":"start","direction":"column","gap":3,"padding":0},"children":[{"text":{"_0":"不吃香菜","color":"secondary","style":"meta"}},{"text":{"_0":"蹲一个延迟实测","color":"primary","style":"body"}}]}}]}},{"flexBox":{"_0":{"alignment":"start","crossAlignment":"start","direction":"row","gap":12,"padding":0},"children":[{"button":{"actionID":"pause","label":"暂停","style":"secondary"}},{"button":{"actionID":"cycleFilter","label":"过滤 · SC","style":"primary"}},{"button":{"actionID":"markRead","label":"已读","style":"secondary"}}]}}]}}"#
        #expect(try GlassNodeEncoder.canonicalJSON(screen) == expected)
    }

    @Test("statusScreen 快照")
    func statusScreenSnapshot() throws {
        let screen = ComposerFixtures.composer.statusScreen(status: ComposerFixtures.streamOnlyStatus)
        let expected = #"{"flexBox":{"_0":{"alignment":"start","crossAlignment":"stretch","direction":"column","gap":12,"padding":20},"children":[{"flexBox":{"_0":{"alignment":"start","crossAlignment":"center","direction":"row","gap":12,"padding":0},"children":[{"icon":{"_0":"checkmarkCircle"}},{"text":{"_0":"LIVE","color":"primary","style":"meta"}},{"text":{"_0":"01:07:23","color":"secondary","style":"meta"}},{"text":{"_0":"推流模式","color":"secondary","style":"meta"}}]}},{"flexBox":{"_0":{"alignment":"center","crossAlignment":"center","direction":"column","gap":8,"padding":0},"children":[{"text":{"_0":"已直播","color":"secondary","style":"meta"}},{"text":{"_0":"01:07:23","color":"primary","style":"heading"}}]}},{"flexBox":{"_0":{"alignment":"start","crossAlignment":"stretch","direction":"row","gap":12,"padding":0},"children":[{"flexBox":{"_0":{"alignment":"start","crossAlignment":"start","direction":"column","gap":6,"padding":16},"children":[{"text":{"_0":"码率","color":"secondary","style":"meta"}},{"text":{"_0":"2.4 Mbps","color":"primary","style":"body"}}]}},{"flexBox":{"_0":{"alignment":"start","crossAlignment":"start","direction":"column","gap":6,"padding":16},"children":[{"text":{"_0":"帧率","color":"secondary","style":"meta"}},{"text":{"_0":"24 fps","color":"primary","style":"body"}}]}}]}},{"flexBox":{"_0":{"alignment":"start","crossAlignment":"stretch","direction":"row","gap":12,"padding":0},"children":[{"flexBox":{"_0":{"alignment":"start","crossAlignment":"start","direction":"column","gap":6,"padding":16},"children":[{"text":{"_0":"网络","color":"secondary","style":"meta"}},{"text":{"_0":"良好","color":"primary","style":"body"}}]}},{"flexBox":{"_0":{"alignment":"start","crossAlignment":"start","direction":"column","gap":6,"padding":16},"children":[{"text":{"_0":"眼镜温度","color":"secondary","style":"meta"}},{"text":{"_0":"正常","color":"primary","style":"body"}}]}}]}},{"flexBox":{"_0":{"alignment":"center","crossAlignment":"center","direction":"row","gap":0,"padding":0},"children":[{"text":{"_0":"当前平台无弹幕通道 · 互动请看手机","color":"secondary","style":"meta"}}]}}]}}"#
        #expect(try GlassNodeEncoder.canonicalJSON(screen) == expected)
    }

    @Test("alertScreen 快照")
    func alertScreenSnapshot() throws {
        let screen = ComposerFixtures.composer.alertScreen(
            fault: .thermal(.hot), degradedPreset: CameraPreset(quality: .medium, frameRate: 24))
        let expected = #"{"flexBox":{"_0":{"alignment":"start","crossAlignment":"stretch","direction":"column","gap":12,"padding":20},"children":[{"flexBox":{"_0":{"alignment":"start","crossAlignment":"center","direction":"row","gap":12,"padding":0},"children":[{"icon":{"_0":"checkmarkCircle"}},{"text":{"_0":"LIVE","color":"primary","style":"meta"}},{"text":{"_0":"推流中","color":"secondary","style":"meta"}}]}},{"flexBox":{"_0":{"alignment":"center","crossAlignment":"center","direction":"column","gap":16,"padding":0},"children":[{"icon":{"_0":"warning"}},{"text":{"_0":"眼镜温度偏高","color":"primary","style":"heading"}},{"text":{"_0":"画质已自动降为 504×896 · 24fps","color":"secondary","style":"body"}},{"text":{"_0":"直播未中断，建议阴凉处继续","color":"secondary","style":"body"}}]}},{"flexBox":{"_0":{"alignment":"start","crossAlignment":"start","direction":"row","gap":12,"padding":0},"children":[{"button":{"actionID":"ackAlert","label":"知道了","style":"primary"}},{"button":{"actionID":"endLive","label":"结束直播","style":"secondary"}}]}}]}}"#
        #expect(try GlassNodeEncoder.canonicalJSON(screen) == expected)
    }

    @Test("相同输入重复编码产出字节级一致（幂等去重前提）")
    func canonicalJSONIsStable() throws {
        let make = {
            ComposerFixtures.composer.danmakuScreen(
                events: ComposerFixtures.danmakuEvents, mode: .all, status: ComposerFixtures.liveStatus)
        }
        let first = try GlassNodeEncoder.canonicalJSON(make())
        let second = try GlassNodeEncoder.canonicalJSON(make())
        #expect(first == second)
    }
}
