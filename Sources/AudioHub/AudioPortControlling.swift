// 系统音频端口操作抽象（AudioHub 实现细节，非 Contracts 契约面）。
// 真实实现：App/Adapters/Streaming/HFPAudioPortAdapter.swift（AVAudioSession/AVAudioEngine）；
// 测试实现：MockPorts。AudioRouteController 只经此协议触碰系统端口，路由状态机因此可全单测。
import Foundation

public protocol AudioPortControlling: Sendable {
    /// 建立指定音源的系统路由。
    /// - glassesHFP：AVAudioSession .playAndRecord + .allowBluetoothHFP + setPreferredInput(bluetoothHFP)
    /// - iphoneMic：内置麦克风
    /// - muted：控制器不会以 muted 调用本方法（静音无系统路由）
    /// 失败抛错（如可用输入里没有目标端口）。
    func configureRoute(for source: AudioSource) async throws

    /// 校验当前系统路由输入是否与音源一致。
    /// HFP 场景在 settling 稳定窗口结束后调用（官方顺序约束：路由未稳时校验会误判）。
    func verifyRoute(for source: AudioSource) async -> Bool

    /// 停用当前路由：移除采集 tap、停引擎、释放会话。要求幂等。
    func teardown() async
}
