// 三档过滤循环状态机（纯值类型，可直接单测）。
// 输入两类：带 actionID 的 tap（真实 DAT 由组件 onClick 上报；
// 契约的 captouch 流只有裸手势，无法定位 tap 区域——契约缺口见集成报告）
// 与裸 captouch 手势。
// 规则：tap 在 "cycleFilter" 区 → 档位 next；.backOnRoot → 上报"请求结束"，不直接结束。
import Foundation
import GlassesKit

public struct DanmakuFilterMachine: Sendable, Equatable {

    public static let cycleFilterActionID = "cycleFilter"

    public enum Event: Sendable, Equatable {
        case tap(actionID: String)
        case gesture(CaptouchGesture)
    }

    public enum Effect: Sendable, Equatable {
        case none
        case modeChanged(DanmakuFilterMode)
        case endLiveRequested
    }

    public private(set) var mode: DanmakuFilterMode

    public init(mode: DanmakuFilterMode = .all) {
        self.mode = mode
    }

    @discardableResult
    public mutating func handle(_ event: Event) -> Effect {
        switch event {
        case .tap(let actionID):
            guard actionID == Self.cycleFilterActionID else { return .none }
            mode = mode.next
            return .modeChanged(mode)
        case .gesture(.backOnRoot):
            return .endLiveRequested
        case .gesture(.tap):
            // 裸 tap 无区域信息，交由带 actionID 的通道处理
            return .none
        }
    }
}
