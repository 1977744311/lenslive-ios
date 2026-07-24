# LensLive

把 Meta Ray-Ban Display 变成「POV 直播机位 + 挂在眼前的弹幕监视器」——手机是导播台，眼镜是机位和提词屏。

- 平台：iOS 17+ · Swift 6 · SwiftUI
- 设计与需求：见任务仓库 `steven-ai-lab/tasks/2026-07-24-meta-display-眼镜原生-app-开发与最新-sdk-能力调研/`（PRD、架构、定稿 mockup 画布）
- 状态：M0（无真机可跑的全量代码 + Mock 联调）；真机验证清单见研究文档 §7

## 架构

```
上行（推流）：眼镜相机 → GlassesKit → StreamEngine(HaishinKit) → RTMP
下行（弹幕）：B 站开放平台 → DanmakuCore → GlassRenderer → GlassesKit → 眼镜屏
两条管线共享一个 DAT 会话，独立降级（弹幕挂了不断播，推流挂了弹幕还在）。
```

| 模块 | 职责 | 真实 SDK |
|------|------|---------|
| `DanmakuCore` | B 站开放平台签名/WS 协议/事件模型/聚合节流 | 无（URLSession + CryptoKit） |
| `GlassesKit` | DAT 会话抽象、Mock 会话、断连重挂编排 | MWDAT（适配器在 App 层） |
| `GlassRenderer` | 眼镜四屏布局树、三档过滤、驻留调度、节流发送 | 无 |
| `StreamEngine` | RTMP 目标/预设/重推状态机/统计 | HaishinKit（适配器在 App 层） |
| `AudioHub` | 音源三选一路由（HFP 顺序约束与回退） | AVFoundation（适配器在 App 层） |
| `LensLiveCore` | SessionCoordinator 总状态机（就绪位图/独立降级/时序） | 无 |
| `App/` | SwiftUI 四屏（照定稿 mockup）、主题 token、Keychain、Mock 运行时 | MWDAT + HaishinKit |

库层（`Package.swift`）零第三方依赖，`swift test` 在 macOS 直接跑；真实 SDK 绑定全部收敛在 App 工程（`project.yml`），适配器以 `canImport` 守护。

## 开发

```bash
swift test                 # 142 个单测（XCTest + Swift Testing），全离线
xcodegen generate          # 生成 LensLive.xcodeproj（首次或 project.yml 变更后）
open LensLive.xcodeproj    # App target 挂 MWDAT + HaishinKit，模拟器可跑 Mock 模式
```

本地推流联调见 `Tools/rtmp-local/README.md`。

## 真机前置（M1）

1. Meta Wearables Developer Center 注册 app 拿配置；Meta AI app v272+、眼镜固件 V127+、眼镜端安装 DAT。
2. B 站开放平台个人入驻（弹幕通道），身份码在 App 内绑定。
3. 按研究文档 §7 清单验证：stream+display 共存、休眠中 send 行为、1Hz 节流实测、续航发热、HFP 音质。
