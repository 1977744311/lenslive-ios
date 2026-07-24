import Foundation
import Testing
import GlassRenderer
import GlassesKit

@Suite("DanmakuFilterMachine 三档循环")
struct DanmakuFilterMachineTests {

    @Test("cycleFilter 区 tap 按 全部 → 仅SC → 暂停 → 全部 循环")
    func cyclesThroughThreeModes() {
        var machine = DanmakuFilterMachine()
        #expect(machine.mode == .all)

        #expect(machine.handle(.tap(actionID: "cycleFilter")) == .modeChanged(.highValueOnly))
        #expect(machine.handle(.tap(actionID: "cycleFilter")) == .modeChanged(.paused))
        #expect(machine.handle(.tap(actionID: "cycleFilter")) == .modeChanged(.all))
        #expect(machine.mode == .all)
    }

    @Test("backOnRoot 只上报请求结束，不改档位")
    func backOnRootReportsEndRequest() {
        var machine = DanmakuFilterMachine(mode: .highValueOnly)
        #expect(machine.handle(.gesture(.backOnRoot)) == .endLiveRequested)
        #expect(machine.mode == .highValueOnly)
    }

    @Test("其他 actionID 与裸 tap 均被忽略")
    func ignoresUnrelatedInputs() {
        var machine = DanmakuFilterMachine()
        #expect(machine.handle(.tap(actionID: "pause")) == .none)
        #expect(machine.handle(.tap(actionID: "markRead")) == .none)
        #expect(machine.handle(.gesture(.tap)) == .none)
        #expect(machine.mode == .all)
    }
}
