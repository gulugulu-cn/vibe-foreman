# Claude Hub

把 MacBook 的刘海变成本地 AI 编程 agent 的控制中心。

同时跑七八个 Claude Code 会话的时候，最难受的是两件事：**不知道哪个在等你**，
以及**知道了也切不过去**。Claude Hub 解决的就是这两件事。

<p align="center">
  <img src="docs/screenshots/01-hover.png" width="620" alt="鼠标经过刘海，露出每个会话的像素小人">
</p>

鼠标经过刘海就展开。每个会话一个小人：**敲键盘 = 在干活，举手 = 在等你，
静止 = 空闲**。需要你处理的那个会被琥珀色光晕框住，名字直接顶在下面 ——
不用逐个去认颜色。

## 下载

[**最新版本**](../../releases/latest) · macOS 26+ · Apple Silicon 和 Intel 通用

1. 打开 dmg，把 **Claude Hub** 拖进「应用程序」
2. 双击 **安装 hook.command**
3. `open -a "Claude Hub"`

> 应用是自签名未公证的，首次打开需要**右键 → 打开**，
> 或者 `xattr -dr com.apple.quarantine "/Applications/Claude Hub.app"`。

## 它能做什么

### 一眼看清七个会话在干嘛

<img src="docs/screenshots/02-expanded-sessions.png" width="560" alt="展开后的会话列表">

点小人展开。上面是选中会话的全貌：**当前目录、分支、未提交数、最近提交、
运行了多久、在哪个终端里**。下面是全部会话，等你处理的永远排第一。

分支和目录不是装饰 —— 同一个项目经常开好几个会话，只看项目名它们长得一模一样。

### 点一下回到那个终端

这是这个工具最初被做出来的原因。旧的做法是靠窗口名做字符串匹配，
而 tmux 的 `automatic-rename` 会把窗口名改成前台进程名（实测出现过窗口名变成
`2.1.173`——那是 claude 的版本号），十个窗口能对上两个。

现在全程只用整数 PID 和 UUID：状态读 Claude Code 自己维护的
`~/.claude/sessions/<PID>.json`，跳转用 iTerm 的 `jobPid` 向上走进程树。
tmux 会话和非 tmux 会话都覆盖。

### 从岛上直接开项目

<img src="docs/screenshots/03-expanded-projects.png" width="560" alt="项目列表，可直接启动">

「开发 xxx」是最高频的动作，不该要求先打开一个主窗口。
跑着会话的项目排前面，点一下就切过去；没跑的点一下直接起一个。
右侧的 `⋯` 里可以选 `--continue`、跳过权限、只开终端等等。

### 高风险操作在岛上拦一下

如果你和很多人一样开着 `--dangerously-skip-permissions`，那就没有任何刹车了。
Claude Hub 只拦**不可逆**的那一档（`rm -rf /`、`git push --force` 到 main、
`drop database`、`kubectl delete` 之类），弹在岛上，拒绝是超时的默认值。

日常的危险操作（`rm -rf ./tmp`、`git reset --hard`）默认**只记录不拦截** ——
按日常用量拦上这一档每天要弹三到八次，结果必然是你把整个功能关掉。
先看一周审批日志，再决定要不要收紧。

### 深挖用的主窗口

<img src="docs/screenshots/04-main-window.png" width="720" alt="主窗口">

岛负责「一瞥」，主窗口负责「深挖」：token 用量趋势、项目管理、审批日志。

## 工作原理

不做任何猜测，四个数据源都是权威的：

| 要回答的问题 | 数据来源 |
|---|---|
| 哪些会话在跑、状态是什么 | `~/.claude/sessions/<PID>.json`（Claude Code 自己写的） |
| 这个会话在哪个终端 | iTerm 的 `jobPid` + 进程树祖先链求交 |
| 干完了 / 要授权了 | Claude Code 的 `Stop` / `Notification` / `PreToolUse` hook |
| 分支、变更数、提交记录 | 按会话的 cwd 直接跑 `git` |

hook 走 Unix socket 和应用通信。**应用没在运行时立即放行** ——
一个监控工具不该让你的命令跑不起来。

## 常见问题

**要装什么依赖吗？**
不用。零第三方依赖，一个 2.3 MB 的应用。

**必须用 tmux 或 iTerm 吗？**
不必须。tmux 和 iTerm 里的会话跳转最准；其它终端会降级成"把终端拉到前面"。

**会读我的代码吗？**
不会。只读 `~/.claude/sessions/` 里的状态文件，以及在项目目录跑 `git status` /
`git log`。不联网。

**Intel Mac 能用吗？**
能，包是 universal 的。要求 macOS 26+。

**支持 Codex / Gemini CLI 吗？**
还不支持，目前只认 Claude Code。

## 已知限制

- 外接显示器上的胶囊形态代码写了但没在 4K 屏上实测过
- 应用未经 Apple 公证，首次打开要绕一下 Gatekeeper

## 许可

MIT
