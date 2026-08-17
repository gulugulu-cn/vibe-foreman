# 参与共创

先说结论：**欢迎，而且有几件事是真的缺人做**（往下翻到「现在最缺什么」）。

## 跑起来

```bash
git clone https://github.com/gulugulu-cn/vibe-foreman.git ~/Documents/code/vibe-foreman
cd ~/Documents/code/vibe-foreman
bash scripts/setup.sh          # 编译 + 安装到 /Applications
cd HubKit && swift test        # 617 个测试，约 45 秒
```

需要 **macOS 26 SDK（Xcode 26）** —— 灵动岛依赖 Liquid Glass API，这是硬门槛。
零第三方依赖，`swift build` 之外什么都不用装。

改完代码重新装：

```bash
bash scripts/build-swift-app.sh     # 几秒，只编当前架构
bash scripts/release.sh             # 打 universal + dmg，几分钟
```

## 这个仓库的写法

代码风格没什么特别的，但**注释和测试的写法是有讲究的**，PR 会按这个看。

### 注释写「为什么」，不写「是什么」

```swift
// ✗ 不要：检查目录是否存在
// ✓ 要：
// tmux 对不存在的 `-c` 目录**返回 0 并静默回落到家目录** ——
// 实测 exit=0，pane_current_path 变成 /Users/xxx。`open /不存在` 则什么都不做。
// 两者都不报错，于是一条坏数据表现成"右键菜单坏了"。
```

代码本身已经说清楚"是什么"了。值得写下来的是**下一个人（包括三个月后的你）会踩的那个坑**：
为什么不用那个看起来更简单的写法、这个魔数是怎么来的、改成另一种会怎样。

`HubKit/NOTES.md` 里攒着所有实机撞出来的坑，改动碰到相关的地方请顺手补一条。

### 测试钉的是边界，不是覆盖率

优先测**写错了不会报错、只会静默失灵**的那些判断。这个仓库里几乎每个测试
都对应一次真实事故，测试的文档注释里写着那次事故是什么样的：

```swift
/// **绑不到 pane 的不算 detached。**
///
/// 那是「根本不在 tmux 里」——VS Code 扩展、直接开的终端、后台任务。
/// 它们有没有终端连着这里判断不了，报成 detached 就是拿"不知道"当结论，
/// 会让一堆正常会话集体显示成"终端已关"。
```

### 中文注释

现有代码全是中文注释，继续用中文即可。代码标识符用英文。

## 提 PR 之前

```bash
cd HubKit && swift test        # 必须全过
```

commit message 用中文，写清楚**为什么这么改**，不只是改了什么。
碰到用户可见的行为变化，请一并更新 README。

## 现在最缺什么

按优先级，都是真实的缺口，不是造出来的任务：

### 1. 终端支持（最缺）

现在只有 **iTerm2** 能精准跳转到具体 tab，Terminal.app 只能前置。
Ghostty / Warp / Kitty / WezTerm 的用户点「跳转终端」**完全没反应**。

这是目前最硬的门槛。跳转的核心算法（进程树祖先链求交，见
`HubJump/JumpEngine.swift`）是终端无关的，缺的是每个终端的「枚举会话 + 前置指定
tab」适配层 —— 参考 `HubJump/ITermLocator.swift`，一个终端一个文件。

**只做到"把终端拉到前面"也是巨大的改进**，不必一步到位做到精准 tab。

### 2. 支持别的 AI CLI

目前只认 Claude Code（读它的 `~/.claude/sessions/<PID>.json`）。
Codex 的 `~/.codex/sessions/` 调研过、结构接得上，
难点在"在跑还是在等"这一层要另走一条路 —— Claude Code 有权威的 `status` 字段，
别家不一定有。

### 3. 公证（Notarization）

现在是自签名，别人下载后要绕 Gatekeeper。这需要 Apple Developer Program
账号，不是纯代码问题，但如果你有经验，`scripts/release.sh` 里加一段
`notarytool` 就能让"双击即用"成立。

### 4. 外接屏上的胶囊形态

岛跟随光标换屏做完了，但**没在 4K 屏上逐项核对过**。
有外接屏的话，帮忙看一眼尺寸和位置对不对就很有价值。

## 有想法但不确定要不要做？

直接开 issue 聊。这个工具是从一个人的真实工作流里长出来的，
很多设计取舍（比如「盯梢默认全关」「审批只拦不可逆那一档」）都有具体理由，
先聊一下能省掉双方的返工。
