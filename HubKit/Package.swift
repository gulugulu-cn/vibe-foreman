// swift-tools-version: 6.0
import PackageDescription

// 平台底线定在 macOS 26：灵动岛依赖 Liquid Glass（.glassEffect / GlassEffectContainer），
// 这是 macOS 26 才有的 API。本项目是给这台机器用的个人工具，不需要向下兼容。
let package = Package(
    name: "HubKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "HubCore", targets: ["HubCore"]),
        .library(name: "HubProbe", targets: ["HubProbe"]),
        .library(name: "HubJump", targets: ["HubJump"]),
        .library(name: "HubIPC", targets: ["HubIPC"]),
        .library(name: "HubProjects", targets: ["HubProjects"]),
        .library(name: "HubUI", targets: ["HubUI"]),
        .executable(name: "hubprobe", targets: ["HubProbeCLI"]),
        .executable(name: "hubctl", targets: ["hubctl"]),
        .executable(name: "ClaudeHub", targets: ["ClaudeHubApp"]),
    ],
    targets: [
        // 纯数据模型，无副作用，不依赖任何系统调用。
        .target(name: "HubCore"),

        // 会话探测：读 ~/.claude/sessions/*.json、进程树、tmux 拓扑。
        .target(name: "HubProbe", dependencies: ["HubCore"]),

        // 跳转引擎：从 sessionId 定位并前置到具体终端 tab。
        .target(name: "HubJump", dependencies: ["HubCore", "HubProbe"]),

        // hook ↔ app 的 Unix socket 协议、风险分级。
        // 刻意不依赖 HubProbe：hubctl 要保持极小、启动极快（每次工具调用都跑一遍）。
        .target(name: "HubIPC", dependencies: ["HubCore"]),

        // projects.yaml、git 状态、token 用量、终端派发。
        .target(name: "HubProjects", dependencies: ["HubCore", "HubProbe"]),

        // 灵动岛与主窗口的 SwiftUI 层。
        .target(
            name: "HubUI",
            dependencies: ["HubCore", "HubProbe", "HubJump", "HubIPC", "HubProjects"]
        ),

        // 开发期 CLI：把探测和跳转的结果打出来，便于在没有 UI 时验证。
        // 目录名不能叫 hubprobe —— macOS 文件系统大小写不敏感，会和 HubProbe 撞。
        .executableTarget(
            name: "HubProbeCLI",
            dependencies: ["HubCore", "HubProbe", "HubJump", "HubProjects"]
        ),

        // Claude Code hook 的执行体。每次工具调用都会跑，必须小而快。
        .executableTarget(name: "hubctl", dependencies: ["HubIPC"]),

        // app 本体。刻意做薄：只有 @main 和窗口装配，逻辑全在 HubKit 各库里。
        .executableTarget(name: "ClaudeHubApp", dependencies: ["HubUI"]),

        .testTarget(name: "HubCoreTests", dependencies: ["HubCore"]),
        .testTarget(name: "HubProbeTests", dependencies: ["HubProbe"]),
        .testTarget(name: "HubJumpTests", dependencies: ["HubJump"]),
        .testTarget(name: "HubIPCTests", dependencies: ["HubIPC"]),
        .testTarget(name: "HubProjectsTests", dependencies: ["HubProjects"]),
        .testTarget(name: "HubUITests", dependencies: ["HubUI"]),
    ]
)
