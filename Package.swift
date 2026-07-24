// swift-tools-version: 6.0
// LensLiveKit — 纯逻辑层零第三方依赖，swift test 可在 macOS 直接跑。
// 真实 SDK（MWDAT / HaishinKit）绑定收敛在 App 工程（见 project.yml），
// 适配器源文件位于 App/Adapters/ 并以 canImport 守护。
import PackageDescription

let package = Package(
    name: "LensLiveKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "DanmakuCore", targets: ["DanmakuCore"]),
        .library(name: "GlassesKit", targets: ["GlassesKit"]),
        .library(name: "GlassRenderer", targets: ["GlassRenderer"]),
        .library(name: "StreamEngine", targets: ["StreamEngine"]),
        .library(name: "AudioHub", targets: ["AudioHub"]),
        .library(name: "LensLiveCore", targets: ["LensLiveCore"]),
    ],
    targets: [
        .target(name: "DanmakuCore"),
        .target(name: "GlassesKit"),
        .target(name: "GlassRenderer", dependencies: ["GlassesKit", "DanmakuCore"]),
        .target(name: "StreamEngine"),
        .target(name: "AudioHub"),
        .target(name: "LensLiveCore", dependencies: [
            "DanmakuCore", "GlassesKit", "GlassRenderer", "StreamEngine", "AudioHub",
        ]),
        .testTarget(name: "DanmakuCoreTests", dependencies: ["DanmakuCore"]),
        .testTarget(name: "GlassesKitTests", dependencies: ["GlassesKit"]),
        .testTarget(name: "GlassRendererTests", dependencies: ["GlassRenderer"]),
        .testTarget(name: "StreamEngineTests", dependencies: ["StreamEngine"]),
        .testTarget(name: "AudioHubTests", dependencies: ["AudioHub"]),
        .testTarget(name: "LensLiveCoreTests", dependencies: ["LensLiveCore"]),
    ]
)
