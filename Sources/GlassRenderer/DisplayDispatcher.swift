// 节流发送器（actor + 时钟注入）。
// GlassNode → canonicalJSON → 与上次已上屏内容相同则跳过（幂等去重）；
// 节流窗口内（默认 1s）合并只发最新；经注入的 GlassesSessionProviding 发送。
// 失败分类：断连（GlassesSessionError.isDisconnection）→ 缓存待重挂后重发；
// 其余（渲染失败等）→ 丢弃本帧，等下一批内容自然刷新。
import Foundation
import GlassesKit
import DanmakuCore

public actor DisplayDispatcher {

    private let session: any GlassesSessionProviding
    private let clock: any Clock_
    private let window: TimeInterval

    private var lastSentJSON: String?
    private var pendingJSON: String?
    private var windowTask: Task<Void, Never>?
    private var inFlight = false
    private var cachedForResendPayload: DisplayPayload?

    public init(session: any GlassesSessionProviding,
                clock: any Clock_ = SystemClock(),
                window: TimeInterval = 1.0) {
        self.session = session
        self.clock = clock
        self.window = window
    }

    // MARK: - 检视（测试/上层可读）

    public var lastSentPayload: DisplayPayload? {
        lastSentJSON.map(DisplayPayload.init(canonicalJSON:))
    }

    /// 断连期间缓存的最后一帧（待重挂重发）
    public var cachedForResend: DisplayPayload? { cachedForResendPayload }

    // MARK: - 入口

    public func submit(_ node: GlassNode) async {
        guard let json = try? GlassNodeEncoder.canonicalJSON(node) else { return }  // 编码失败视作渲染失败：丢帧
        if inFlight || windowTask != nil {
            pendingJSON = json   // 窗口内合并只留最新；窗口结束时再与 lastSent 去重
            return
        }
        guard json != lastSentJSON else { return }
        await send(json)
    }

    /// 断连恢复、display 重挂完成后由上层调用：重发缓存帧
    public func resendPendingAfterReattach() async {
        guard let payload = cachedForResendPayload else { return }
        cachedForResendPayload = nil
        await send(payload.canonicalJSON)
    }

    public func shutdown() {
        windowTask?.cancel()
        windowTask = nil
        pendingJSON = nil
    }

    // MARK: - 内部

    private func send(_ json: String) async {
        inFlight = true
        defer { inFlight = false }
        do {
            try await session.sendDisplayPayload(DisplayPayload(canonicalJSON: json))
            lastSentJSON = json
            cachedForResendPayload = nil
        } catch let error as GlassesSessionError where error.isDisconnection {
            // 断连：缓存最新一帧待重挂重发；不开窗口（连不上时无节流意义）
            cachedForResendPayload = DisplayPayload(canonicalJSON: json)
            return
        } catch {
            // 其余失败：丢弃本帧
        }
        openWindow()
    }

    private func openWindow() {
        windowTask = Task { [clock, window] in
            do { try await clock.sleep(seconds: window) } catch { return }
            guard !Task.isCancelled else { return }
            await self.windowElapsed()
        }
    }

    private func windowElapsed() async {
        windowTask = nil
        guard let json = pendingJSON else { return }
        pendingJSON = nil
        guard json != lastSentJSON else { return }
        await send(json)
    }
}
