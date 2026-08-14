# HubKit 实现笔记

记录实测踩到的坑和不显然的结论。这些都是在本机验证过的，不是推测。

## Liquid Glass

### GlassEffectContainer 会把全部子视图纳入玻璃合成

**症状**：内容层的文字被玻璃材质糊成一团，完全不可读；调试底色能正常显示，
说明布局位置是对的，纯粹是被材质糊了。

**原因**：`GlassEffectContainer` 不只作用于挂了 `.glassEffect` 的子视图，
它的**所有**子视图都会进入玻璃合成。

**做法**：容器里只放外壳，内容层留在容器外、叠在它上面。

```swift
ZStack(alignment: .top) {
    GlassEffectContainer(spacing: 22) { shell }   // 只有外壳
    contentLayer                                   // 内容在容器外
}
```

### 文字可读性靠 scrim，不靠逐字阴影

玻璃高度透明，壁纸一换文字就可能完全读不出来。在玻璃层之上、内容层之下铺一层
随形状裁切的黑色渐变遮罩，成本近乎为零，效果远好于给每个 `Text` 挂 shadow
（后者还会在半透明背景上糊出一圈脏边）。

### 深色玻璃上不能用系统的中性灰

`#8E8E93`（系统 secondary label 灰）在压过 scrim 的深色玻璃上**几乎完全看不见** ——
那个值是为浅色背景设计的。改成接近白的浅灰，靠**透明度**而不是**灰度**表达"不活跃"。

### Liquid Glass 会跟着背景亮度自适应，压不住就和刘海撞色

**症状**：岛飘到浅色窗口（微信、Finder、文档）上时整块变成灰塑料；
换到纯黑终端上又比刘海亮一截。两种情况下岛和刘海之间都有一条明显的分界线。

**原因**：`.glassEffect(.regular)` 会做背景亮度补偿 —— 背景亮它变亮、背景暗它变亮
（后者是为了让盖在上面的内容可读）。而岛顶着的物理刘海**恒为纯黑**，
材质自己在漂，怎么调都对不齐。

**做法**：三件事一起做，缺一不可。

1. **用 `.clear` 而不是 `.regular`**，并压一层固定的黑色 tint。
   `.clear` 不做亮度补偿，最终亮度完全由自己的 tint + scrim 决定。
2. **scrim 按两端极值定，不按好看定。** 白底下 `1 × (1−tint) × (1−scrim)` 要落在
   0.15 附近才和刘海同色系；黑底下又不能把玻璃压没。0.7 上下是这两个约束的交集 ——
   低于 0.6 黑底发灰，高于 0.85 白底就成了不透明黑块。
3. **刘海下沿加一段 44pt 的黑色渐隐**（`IslandTheme.notchBlend`）。
   不透光的刘海和半透明玻璃直接相接必然有亮度落差，渐隐区间要比刘海本身还高，
   太短只会把"硬边"变成"软边"，问题性质没变。

另外**边缘高光是玻璃感的关键一笔**（`IslandTheme.edgeHighlight`）：真实玻璃的边缘
因折射比中间亮，下沿尤其明显。没有这条边，再透明也只会被读成一块半透明色块。

### 展开态要牺牲质感换可读性

实测岛飘在 Finder 上时，背后的文件名会直接穿透上来糊在会话名下面。
折叠 / 悬停是"看一眼"的形态（内容少、字大），可以留足玻璃感；
展开和审批是"读"的形态，**那两个形态里可读性优先**，scrim 要再压一档。

### 结论：Liquid Glass 和"贴合刘海"物理上互斥

调了三轮参数才认清这件事，所以写在最前面。

`.glassEffect` 的设计目标是"盖在任何东西上，上面的内容都可读"，
于是它**跟着背景亮度双向补偿**：背景亮它变亮，背景暗它**也**变亮。
而刘海恒为纯黑。实测（`.clear` + 黑 tint）：

| 背景 | 玻璃输出 | 压 0.72 黑罩后 | 刘海 |
|---|---|---|---|
| 白底 Finder | ≈ 1.0 | 0.28（中灰） | 0 |
| 纯黑终端 | ≈ 0.45 | 0.13 | 0 |

白底下要压到刘海那个黑需要 scrim ≈ 0.94，那时"玻璃"已经不存在了。
换 `NSVisualEffectView`（各种 material 都试过）同样如此 ——
**任何"能透出背景"的材质，白底上都必然比黑底上亮**，差别只是程度。

最后的做法：一层**固定不透明度的暗色基底**（`IslandTheme.baseOpacity = 0.86`），
亮度只由它决定，和背景无关：

    最终亮度 ≈ 背景亮度 × (1 − 0.86)
    白底 → 0.14      黑底 → 0      刘海 → 0

留下的 14% 就是"还看得出背后有东西"的量。玻璃质感改由**背景模糊**
（`IslandBackdrop`）和**边缘高光**（`IslandTheme.edgeHighlight`）承担。

### 悬停要有形状二次判定 + 停留延迟

`NSTrackingArea` **只能是矩形**。折叠态的岛是个上窄下宽的异形，用它的包围盒
做热区就是 217×52pt 的一整块，横跨刘海两侧的菜单栏 ——
鼠标去点右上角图标时路过就会把岛弹出来。

两件事都要做：
1. 拿到指针位置后，**再用岛的实际形状（`hitPath`）判一次**；
2. 加 250ms 的**停留延迟**，横穿而过不触发。

只做其中一件都不够：没有形状判定，热区太宽；没有延迟，擦边而过也会触发。

## 窗口

### 非 key 窗口的点击会被整个吞掉 —— `acceptsFirstMouse`

**症状**：岛显示正常，但**任何点击都没反应** —— 展开点不动、列表行点不动、
审批按钮点不动。没有任何报错。

**原因**：AppKit 的规则是，点击一个**非 key 窗口**时，如果目标视图的
`acceptsFirstMouse(for:)` 返回 false，这次点击只用来切换 key 状态，
**不会派发给视图**。`NSHostingView` 默认返回 false。

而这个 app 是 `.accessory`（永远不是活跃 app）、panel 是 `.nonactivatingPanel`
（点它不激活也基本不成为 key），于是**每一次点击都算 "first mouse"**。

**做法**：`IslandHostingView` 覆写 `acceptsFirstMouse` 返回 true。
一行代码，但不写就等于整个岛是张图片。

### `NSHostingView.isFlipped` 是可读写属性，不能假设

SDK 里的声明是 `@objc final override public var isFlipped: Bool { get set }` ——
`final` 所以子类**不能覆写**，可读写所以默认值不属于契约。

`hitTest` 里必须按运行时的 `isFlipped` 归一坐标。猜错的话命中区会整体翻到窗口底部
（720pt 高的窗口，岛在顶部 46pt，翻过来就落在屏幕中间的空气里），
整个岛点不动且没有任何报错 —— 和上面那个坑的症状一模一样，很难区分。

### 悬停要用 `.activeAlways` 的 NSTrackingArea，不能只靠全局 monitor

`NSEvent.addGlobalMonitorForEvents` 拿不到发给本 app 自己的事件，有盲区。
主链路应该是宿主视图上的 `NSTrackingArea`，关键选项是 **`.activeAlways`** ——
它让 mouseEntered / Moved / Exited 在本 app 未激活时照样投递。
默认的 `.activeInKeyWindow` 对一个永远不是 key 的 panel 等于什么都不做。

窗口还必须设 `acceptsMouseMovedEvents = true`，否则 `.mouseMoved` 根本不投递。

### 全局 leftMouseDown monitor 会收到点在自己身上的点击

**症状**：展开态点列表任何一行，岛立刻收起 —— 展开态等于不可用。

**原因**：用全局 monitor 实现"点岛外收起"时，直觉上它只该收到别的 app 的事件。
但本 app 是 `.accessory` 且从不激活，点岛的事件在系统看来并不属于某个活跃 app，
于是照样会收到。

**做法**：回调里拿 `event.locationInWindow`（全局 monitor 里这已经是屏幕坐标）
换算到视图坐标，和 `hitPath` 比一下，落在岛内就忽略。

### 形态切换不能靠替换 `rootView`

`hostingView.rootView = AnyView(...)` 是一次性的树替换，SwiftUI 看到的是
两棵不相干的树：**动画无从发生**（`withAnimation` 和 `.glassEffectID` 都失去前提），
而且**所有 `@State` 归零**（审批面板的时间锁、长按进度、TimelineView 的时钟
每次形态一变就重置）。

形态要放在 `@Observable` 的模型里，rootView 只设一次。

### 系统按钮样式在非活跃窗口里会被去饱和

`.buttonStyle(.glass)` / `.glassProminent` 在非 key 窗口里会整体变灰，看起来像禁用。
审批面板尤其不能这样 —— 用户看到两个灰按钮的第一反应是"点不了"，
而那正是唯一需要他立刻决策的地方。岛上的按钮一律用自绘样式（`IslandButtonStyle`）。

### 只有 selected 行才画背景 = 只有文字可点

**症状**：列表行必须精确点在文字上才有反应，右边一大片空白点不动。

`.contentShape(Rectangle())` 不足以让一行"到处都能点"——没有背景的行，
空白区域没有任何可命中的内容。**每一行都要有常驻背景**（哪怕 0.03 透明度），
顺便还能做悬停反馈。

### 岛必须强制暗色

不是审美偏好。岛的上半截要和物理刘海严丝合缝，而刘海在浅色模式下**也是纯黑**。
做浅色岛会在刘海下沿（`y = notchHeight`）留一条永远消不掉的黑白硬边。

### 逐像素点击穿透要用形状而不是包围盒

窗口是 640×720 的透明块，不处理会吞掉整个屏幕顶部中间区域的点击。
用 `IslandShape` 的实际路径做 `hitTest`：折叠态上半段严格只有刘海那么宽，
两侧的菜单栏图标依然可点；形状变了命中区自动跟着变。

用包围盒近似的话，折叠态两侧多出的 8pt 会压在菜单栏上，把输入法、电量图标吃掉。

### 窗口尺寸恒定，只改内部布局

形态切换绝不调 `NSWindow.setFrame`。窗口 frame 动画走 CoreAnimation 隐式事务，
和 SwiftUI 的 spring 不同步，展开时会看到内容被裁掉一两帧。

## 刘海几何

本机实测（16" M4 Max，默认缩放）：

| | 值 |
|---|---|
| 内建屏 frame | 1728 × 1117 @2x |
| **刘海宽** | **185 pt** |
| **刘海高** | **32 pt** |
| 菜单栏高 | 33 pt |
| 刘海中心 X | 864 pt |
| 外接 LG 4K | 1920×1080，`safeAreaInsets.top = 0`，无刘海 |

注意和常见的"200×37"传闻不一致。**所有布局都必须写成 `notchWidth` 的函数**，
用户改缩放时这个值会变。

## 会话探测与跳转

### 权威状态源是 `~/.claude/sessions/<PID>.json`

Claude Code 自己在写，含 `busy` / `idle` / `waiting` / `shell` 和 `waitingFor`。
不需要任何启发式推断（比如从 pane_title 的 spinner 字符猜 busy）。

死进程的 json 会残留（实测有好几天前的），必须用 `kill(pid, 0)` 过滤。

### 跳转的 join 键是 iTerm 的 `jobPid`

实测排除的方案：
- iTerm session 的 `tty` → tmux `-CC` 会话返回 `missing value`
- `tmuxPaneID` / `tmuxWindowName` / `tmuxPaneTitle` 变量 → 全部 `missing value`
- 外部 `tmux select-window` → `-CC` 模式下会被 iTerm 立刻覆盖

可用方案：`jobPid` 向上走进程树，第一个存在 `sessions/<PID>.json` 的祖先即所有者。

AppleScript 语法有坑：必须写 `tell s to get variable named "jobPid"`，
写成 `variable named "jobPid" of s` 会报 -1723「不允许访问」。

### bg 会话不在任何终端里

`kind: bg` 的会话挂在 `claude bg-pty-host` daemon 下：

```
23402 (claude bg-spare) → 23371 (claude bg-pty-host) → 70305 (claude daemon) → 1
```

祖先链必然连不上终端。用户看它的地方是某个跑 `claude agents` 的 tab，
那是**查看器进程**，与后台会话没有任何亲缘关系。

对 bg 会话破例用 tab 标题匹配 —— 但和旧实现按 `pane_title` 匹配有本质区别：
旧实现匹配 ai-title（每轮都变），这里匹配的是创建时一次性派生的稳定 job 名。
且只在祖先链未认领的 tab 里找、要求名字长度 ≥ 8。

### tmux 窗口名不可信

`automatic-rename` 会把窗口名改成前台进程名，而 **claude 的进程名就是它的版本号** ——
实测出现过窗口名变成 `2.1.173`。旧实现用「窗口名 == projects.yaml 的 name」
判断项目是否运行，实测 9 个窗口只有 2 个匹配得上。身份识别绝不能依赖窗口名。

### iTerm2 的包名是 `iTerm.app`，AppleScript 名才是 `iTerm2`

`/Applications/iTerm.app/Contents/MacOS/iTerm2` —— 只有可执行文件叫 iTerm2。
旧 `isInstalled` 拿 AppleScript 名拼 `/Applications/iTerm2.app`，永远找不到，
`detectTerminal()` 一路降级到 macOS 终端。

**这个 bug 藏了很久**，因为平时 hub session 已存在且有客户端连着，
走的是 `addWindow`，压根不碰终端检测；只有**开机后第一次建 session**
才会走 `createSession` → `detectTerminal()`，于是现象是
「重启后开项目弹的是系统终端」，看起来像和重启有关，其实和重启无关。

判装没装一律走 bundle id + LaunchServices（`NSWorkspace.urlForApplication`），
路径只做兜底 —— 用户可能装在 `~/Applications`、Setapp 目录、或者改过包名。

### macOS 的 `pgrep` 默认不匹配自己的祖先进程

要加 `-a` 才把祖先算进来。所以 `pgrep -x iTerm2` 在**从 iTerm 里跑起来的**
hubctl / hubprobe 里恒为假 —— 跳转会报「iTerm2 未运行」，终端派发会以为
iTerm 没起来而重复 `open`。判 app 在不在跑用
`NSRunningApplication.runningApplications(withBundleIdentifier:)`，
它也不会像 `tell app "iTerm2" to running` 那样触发冷启动。

（同理：CLAUDE.md 里那条「必须用 `pgrep -x ClaudeHub`」讲的是**另一个**坑
—— `-f` 会子串匹配到历史遗留的同名 bundle。两条别混。）

### 关掉终端不会结束会话，`kill(pid, 0)` 判不出来

claude 的父进程是 tmux server，关窗口只是 detach，进程照跑。于是
`ClaudeSessionReader` 的判活依然为真，项目行一直亮着蓝点写「1 个会话」,
而用户明明已经把窗口关了 —— 他会认定界面在撒谎。

界面没撒谎，它只是把「进程活着」当成了「会话在线」。这是两件事，
一颗点表达不了。真相要两半都说：还在跑，但你找不到它了。
判据是 `tmux list-clients -F '#{client_session}'` 里有没有该 pane 所属的会话名
（`SessionStore.detachedIds`）。

两个不能省的边界：
- **按 tmux 会话名判，不是「有没有任何客户端」** —— 客户端可能连在别的 session 上。
- **绑不到 pane 的不算 detached**。那是「根本不在 tmux 里」（VS Code 扩展、
  直接开的终端、bg 任务），有没有终端连着这里判断不了，
  硬报 detached 就是拿"不知道"当结论，会让一堆正常会话集体显示成"终端已关"。

## 打包与签名

### 辅助可执行文件不能放 `Contents/MacOS/`

**症状**：`hubctl` 一执行就返回 `EXIT=137`（SIGKILL），**没有任何错误输出**，
`codesign --verify` 却报告 "valid on disk"。

**原因**：`Contents/MacOS/` 按约定只放 `CFBundleExecutable` 指向的那一个可执行文件。
把辅助工具也放进去、并且用 `codesign --deep --identifier <bundle-id>` 签名时，
两个不同的二进制会声称同一个 bundle identifier。Apple Silicon 上这种签名不匹配
是 exec 瞬间 SIGKILL，不给任何提示。

**做法**：辅助工具放 `Contents/Helpers/`，用自己的 identifier
（`dev.hengjun.claude-hub.hubctl`）单独签名。

### 签名顺序：先内层后外层，不用 `--deep`

```bash
codesign --force --sign "$CERT" --identifier "$BUNDLE_ID.hubctl" App.app/Contents/Helpers/hubctl
codesign --force --sign "$CERT" --identifier "$BUNDLE_ID"        App.app
```

`--deep` 会把外层的 `--identifier` 强加到所有嵌套代码上，正是上面那个坑的来源。
先签内层再签外层时，外层签名会自动把 `Helpers/` 的内容封进 `CodeResources`。

也不要加 `--options runtime`：自签名 + 未公证的情况下 hardened runtime
不提供任何实际保护，反而引入额外的加载限制。

### 构建脚本必须冒烟测试 hubctl

签名问题不会让 `codesign --verify` 失败，只会在**运行时**静默杀进程。
所以 `build-swift-app.sh` 最后会真的跑一次 `hubctl doctor`。

### bash 变量后面紧跟中文标点要加花括号

```bash
log "编译（$CONFIG，SDK $SDK_VERSION）…"    # 报错：CONFIG?: unbound variable
log "编译（${CONFIG}，SDK ${SDK_VERSION}）…" # 正确
```

全角逗号的 UTF-8 字节会被 bash 当成变量名的一部分。

## 审批链路

### 超时阶梯必须严格递增

**真实事故**：`ApprovalCoordinator` 和 hubctl 的读超时都设成 60 秒。两者同时到期，
hubctl 先判定"没收到应答"并按 fail-open **放行**了一条 `git push --force origin main` ——
而服务端那一侧其实已经决定拒绝。超时的语义从"安全拒绝"翻转成了"静默放行"。

正确的阶梯（见 `HookTimeouts`），**内层先到期，外层留足余量收结果**：

| 层 | 超时 | 到期后 |
|---|---|---|
| `ApprovalCoordinator` | 60s | 判定拒绝 |
| `HookCoordinator` | 65s | 等 UI 把拒绝送回 |
| hubctl 读 socket | 75s | 等服务端写回 |
| `settings.json` hook | 90s | Claude 杀进程的上限 |

任何一层反过来，就会出现「内层判定拒绝、外层已超时放行」的危险窗口。

### 「连不上」和「连上但没应答」的默认值是相反的

- **连不上** = Hub 没运行 = 这次调用压根没被审查过 → **放行**。
  不能因为工具没开就让用户的每条命令都失败。
- **连上但没应答** = 服务端认为值得拦截，但决策环节出了问题 → **拒绝**。
  判据是服务端对非高风险操作**立即**应答，能走到无应答说明它拦下了。

所以 `HubSocketClient.send` 返回的是 `HookSendResult` 枚举而不是可选值 ——
把这两种情况混成 `nil` 正是上面那个事故的根源之一。

### hook 进程死了，审批卡不会自己消失

**症状**：岛上挂着一张审批卡，点了也没用 —— 因为**已经没人接收这个结果了**。
更糟的是队列先进先出，这张僵尸卡会一直挡住后面真正需要处理的请求。

**场景**：Claude 被 Ctrl-C、会话被关、hook 进程超时被 kill。服务端此时仍然
阻塞在等决策上，它并不知道对端已经没了。

**做法**：`HookEvent.clientPid` 本来就一路传过来了，用它做定期扫描
（`ApprovalCoordinator.startOrphanSweep()`）：`kill(pid, 0)` 返回 ESRCH 就判定
发起方已死，按**拒绝**收尾并撤掉卡片。`EPERM` 说明进程存在但不属于我们，算活着；
`clientPid == 0`（不知道发起方是谁）绝不能当成已死。

### 排障时 NSLog 的插值会被当成私有数据

`NSLog("...\(text)")` 在 `log show` 里只会显示 `<private>`，等于没打。
要看到内容必须写成 `NSLog("... %{public}@", text)`。

### 在 Bash 工具调用里用 `&` 起的后台进程会被杀掉

调用一返回，`cmd &` 起的进程就没了。测试阻塞式 hook（要等用户在岛上点击）时，
这会表现成"hubctl 立刻退出且没有输出"——看起来和"拒绝被吞成放行"一模一样，
极易误判成安全缺陷。要用工具本身的 `run_in_background` 参数。

## 数据

### 两个 projects.yaml，app 读的不是脚本写的那个

**症状**：主窗口的「项目」「用量」「设置」三个页面全是空的，看起来像"功能没做"。

**原因**：
- 脚本（`add-project.sh` / `scan-projects.sh`）和 CLAUDE.md 都写
  `~/Documents/code/claude-hub/projects.yaml`（21 个项目，格式正常）；
- app 读的是 `~/Library/Application Support/claude-hub/projects.yaml`，
  且那份是坏的 —— 旧版留下 `projects: []`，后来的追加逻辑又往文件尾部加了 117 条：

```yaml
projects: []          ← 解析器看到这行就认定项目段是空的
  - name: claude-hub  ← 后面全部被忽略
```

解析器判的是 `trimmed == "projects:"`，`projects: []` 完全不匹配。

**三处都要改**：
1. 顶层键按**键名**匹配，别做整行字面比较；
2. 追加写入前先把 `projects: []` 规范化成 `projects:`，否则每次扫描都在造这种坏文件；
3. **解析失败必须能被看见** —— 文件里有 `- name:` 却解析出 0 条时给出诊断，
   UI 上把实际读的文件路径显示出来。静默返回空数组是这次排查花时间最多的地方。

### 用量：945 MB 不能整份读进内存

`~/.claude/projects` 实测 **945 MB / 341 个 jsonl**。
原实现对每个文件 `String(contentsOf:)` 再 `split(separator: "\n")`，
跑不出结果，页面永远停在 0 —— 用户读到的就是"这个功能没做"。

改成 `FileHandle` 按 1 MB 分块流式解析 + 按 (path, size, mtime) 增量缓存之后：

| | 耗时 |
|---|---|
| 7 天 · 冷缓存 | 3.6 s |
| 7 天 · 热缓存 | 0.22 s |
| 全部 · 冷缓存 | 4.0 s（363 个会话 / 63474 条消息）|

分块读有个必须写对的细节：**块边界几乎必然落在某行中间**，
残留的尾巴要留到下一块开头拼接。写错的表现是"大文件统计偏低"——
数字只是小一点，不会报错，极难发现。

## 工程

### 日志：`NSLog` 的插值会被隐成 `<private>`

被坑过两次。`NSLog("会话数 \(count)")` 在 `log show` 里只显示 `<private>`。

而 `NSLog("%{public}d", count)` **也是错的** —— `{public}` 是 `os_log` 的格式语法，
`NSLog` 不认，会把 `{public}d` 原样打出来。

只有 `Logger` 的 `privacy:` 参数是对的（见 `HubCore/HubLog.swift`）：

```swift
HubLog.app.notice("已就绪 —— \(count, privacy: .public) 个会话")
```

    log stream --predicate 'subsystem == "dev.hengjun.claude-hub"' --style compact

### 拿哈希值做算术前必须先取模

`abs(seed) * 37` 在 seed 来自哈希（量级接近 `Int.max`）时直接整数溢出，
Swift trap —— 表现是 **app 一显示小人就闪退**。

而当时的单元测试喂的是 `tick * 7919` 这种小整数，完全没碰到。
**测试的输入不真实 = 测试没在测东西。** 现在测试里固定包含
`SpriteSeed.stable(...)` 的真实量级值以及 `Int.max` / `Int.min` 边界。

另外 `abs(Int.min)` 会 trap，用 `.magnitude` 不会。

### 会话形象要用跨进程稳定的哈希

Swift 的 `String.hashValue` **每次进程启动都重新加盐**。
用它派生像素小人的发色/衣服，每次重开 app 所有人的形象都会换一遍，
"记住橙头发那个是 acme-admin"这件事根本立不住。用 FNV-1a 自己算（`SpriteSeed`）。

### 分段拼装的像素图要断言尺寸

小人是「发型 + 脸 + 身体 + 笔记本」四段拼出来的 16×16。
某段少一行、某行少一格，Canvas 只会安静地少画几个方块，画面上表现为"有点歪"。
`SpriteLibraryTests` 对每种发型 × 每个姿势断言 16 行 × 16 列，
第一次跑就抓到了 640 处越界。

### macOS 文件系统大小写不敏感

`Sources/hubprobe` 和 `Sources/HubProbe` 是**同一个目录**。
可执行 target 的目录名不能只靠大小写和库 target 区分。

### 测试 bundle 被系统策略拒绝加载

**症状**：`swift test` 报 `library load denied by system policy` /
`code signature ... not valid for use in process`，测试一个都跑不了。

macOS 26 对 dylib 加载的签名校验更严，`.xctest` bundle 在增量链接后
签名会失效。清掉重建再重签即可：

```bash
rm -rf .build/arm64-apple-macosx/debug/HubKitPackageTests.xctest
swift build --build-tests
codesign --force --sign - .build/arm64-apple-macosx/debug/HubKitPackageTests.xctest
swift test --skip-build
```

### 开发期环境变量

- `HUB_ISLAND_STATE=hover|expanded` —— 钉住某个形态，方便截图核对布局
- `HUB_DEBUG_CONTENT=1` —— 给内容框描红色底，一眼看出它被放在哪、有没有被裁掉
- `HUB_DEBUG=1` —— hubctl 把收到的 `HookSendResult` 打到 stderr。
  排查"拒绝有没有被吞成放行"时唯一能直接看到真相的地方；走 stderr 所以
  开着也不会被 Claude 当成 hook 的决策输出。

### 交互缺陷必须用真实鼠标验证

这一轮的全部交互缺陷（点击被系统吞掉、整行只有文字可点、外部点击监听误伤自己）
在截图上**一个都看不出来** —— 布局、配色、内容全是对的，只是点不动。
必须真的移动鼠标、真的点下去再截图比对。

配套的坑：**先确认光标在哪块屏幕上**。光标跑到外接屏时所有移动都落空，
表现成"悬停功能坏了"，会浪费大量时间去查根本没坏的代码。
