# Claude Hub

Claude Code 本地开发调度中心。用一个 Claude 窗口管理所有项目。

## 功能

- **tmux 多项目管理** — 每个项目一个 tmux 窗口，iTerm2 标签页体验
- **全局通知** — 任何 Claude 做完事 → 桌面弹窗 + 语音提醒（零配置）
- **权限通知** — 任何 Claude 等授权 → 立即提醒你去操作
- **用量统计** — 按项目查看 token 消耗、会话数、模型分布
- **项目发现** — 扫描目录自动生成项目清单
- **浏览器自动化** — Claude in Chrome + DevTools 双引擎协同

## 新电脑完整安装

### 1. 安装前置依赖

```bash
# Homebrew（如果没有）
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# 必需
brew install tmux
brew install terminal-notifier
xcode-select --install

# Claude Code CLI（需要 Node.js）
brew install node
npm install -g @anthropic-ai/claude-code
```

### 2. iTerm2 tmux 集成（setup.sh 自动配置）

项目使用 `tmux -CC` 模式（iTerm2 专属），让 tmux 窗口显示为**原生标签页**。

`setup.sh` 会自动执行以下配置，**无需手动去 GUI 里勾选**：

```bash
# tmux 窗口显示为 iTerm2 标签页（而非独立窗口）
defaults write com.googlecode.iterm2 OpenTmuxWindowsIn -int 2
# 连接后自动隐藏 tmux 控制会话（避免多余的空白标签）
defaults write com.googlecode.iterm2 AutoHideTmuxClientSession -bool true
```

如果需要手动验证，可以打开 iTerm2 → **Settings** (⌘,) → **General** → **tmux** 查看这两项是否已勾选。

### 3. macOS 权限授权

Hub 使用 AppleScript（osascript）自动控制 iTerm2 创建标签页、切换窗口。macOS 需要你授权：

**首次运行时**，系统会弹窗询问"XXX 想要控制 iTerm2"，**必须点允许**。

如果错过了弹窗或不小心拒绝了：

1. 打开 **系统设置** → **隐私与安全性** → **自动化**
2. 找到 **Terminal**（或 **iTerm2**），勾选允许控制 iTerm2
3. 如果列表里没有，运行一次 `osascript -e 'tell application "iTerm2" to activate'` 触发弹窗

### 4. 克隆并初始化

```bash
git clone https://github.com/hengjun-dev/claude-hub.git ~/Documents/code/claude-hub
cd ~/Documents/code/claude-hub

# 一键初始化：注入全局 hooks + 生成语音文件 + 自动编译托盘 app
# Rust 环境不存在会自动安装，首次编译约 2-3 分钟，需下载约 2GB 依赖
bash scripts/setup.sh
```

> **路径说明**：`cc.sh` 启动脚本中硬编码了 `~/Documents/code/claude-hub` 路径。如果你克隆到其他位置，需要修改 `scripts/cc.sh` 第 9 行的 `HUB_DIR` 变量。

### 5. 添加项目

```bash
# 自动扫描目录下所有 git 仓库
bash scripts/scan-projects.sh ~/Documents/code

# 或手动编辑
cp projects.yaml.example projects.yaml
vim projects.yaml
```

### 6. 配置启动别名（推荐）

```bash
echo 'alias cc="bash ~/Documents/code/claude-hub/scripts/cc.sh"' >> ~/.zshrc
source ~/.zshrc
```

之后只需输入 `cc` 即可一键启动调度中心（自动拉起托盘 app + 启动 Claude）。

### 7. 浏览器自动化（可选）

```bash
bash scripts/setup-browser.sh
```

前置要求：
- **Chrome >= 144**（支持 autoConnect 模式）
- **Claude in Chrome 扩展**已安装

配置完成后还需在 Chrome 地址栏输入 `chrome://inspect/#remote-debugging`，点击 **Enable**，然后重启 Claude Code 会话。

### 8. 启动

```bash
cc          # 如果配了别名
# 或
claude      # 在 claude-hub 目录直接启动
```

启动后 Claude 会根据 CLAUDE.md 的启动序列自动执行：拉起通知面板 → 显示项目列表 → 检查 tmux → 报告就绪。

## 前置条件汇总

| 依赖 | 用途 | 安装方式 |
|------|------|---------|
| macOS + iTerm2 | 终端环境 | 手动安装 |
| tmux >= 3.0 | 多窗口管理 + `-CC` 模式 | `brew install tmux` |
| terminal-notifier | 桌面通知弹窗（点击可跳转） | `brew install terminal-notifier` |
| Node.js | Claude Code CLI + MCP 工具 | `brew install node` |
| Claude Code CLI | Claude 命令行 | `npm i -g @anthropic-ai/claude-code` |
| Xcode CLT | 编译 Rust 代码 | `xcode-select --install` |
| Rust | 编译托盘 app | `setup.sh` **自动安装** |

> Apple Silicon（M1/M2/M3/M4）和 Intel Mac 均支持，托盘 app 在本机编译，无架构兼容问题。

> 以下工具为 macOS 内置，无需安装：`say`（语音合成）、`afplay`（音频播放）、`osascript`（AppleScript 执行）、`python3`（JSON 处理）。

## 工作原理

```
你 ← 桌面通知 + 语音 + 托盘面板 ← 全局 Hook
 ↓
Hub Claude（调度中心窗口）
 ├── tmux 窗口: acme-erp     → Claude / 终端
 ├── tmux 窗口: my-api        → Claude / 终端
 └── tmux 窗口: my-frontend   → Claude / 终端
```

Hub 是你和所有项目 Claude 之间的调度层：
- 你说"开发 xxx" → Hub 自动创建 tmux 窗口
- 你说"在 xxx 跑构建" → Hub 发送命令到对应窗口
- 任何窗口的 Claude 做完事 → 你收到通知

## 通知机制（核心功能）

所有 Claude 实例做完事或等授权时，**自动通知你**。零配置，全局生效。

### 工作原理

Claude Code 内置 Hook 机制，在特定事件发生时自动执行 shell 脚本。`setup.sh` 会把两个 hook 注入到全局配置 `~/.claude/settings.json`，所有 Claude 实例共享，无需在每个项目单独配置。

### 完整链路

```
Claude 完成一轮回复
  → 触发 Stop hook（hub-hook-stop.sh）
    → 1. 桌面弹窗通知（点击可跳转到 iTerm2）
    → 2. 语音播报（随机："搞定了，来看看" / "干完了，等你验收" 等 5 种）
    → 3. 写事件 JSON 到 /tmp/hub-signals/events/
    → 4. 发 tmux 信号（唤醒 Hub 中等待的进程）
         ↓
    Tauri 托盘 app 监听到事件文件
      → 面板实时更新事件列表
      → 系统通知

Claude 需要用户授权
  → 触发 Notification hook（hub-hook-permission.sh）
    → 同上链路，但提示语变成"需要你授权" / "在等你点确认"等
```

### 通知渠道

| 渠道 | 说明 | 依赖 |
|------|------|------|
| 桌面弹窗 | macOS 通知中心，点击跳转 iTerm2 | terminal-notifier（推荐），缺失时降级到 osascript |
| 语音播报 | 随机语音，做完/授权各 5 种话术 | say + afplay（macOS 内置） |
| 托盘面板 | 实时事件列表，点击项目可直接跳转 | Tauri app（文件系统监听 /tmp/hub-signals/events/） |
| tmux 信号 | 程序化等待任务完成 | tmux wait-for（Hub 内部使用） |

### 为什么零配置

- Hook 配置在 `~/.claude/settings.json`，对所有 Claude 实例全局生效
- `setup.sh` 一次注入，永久生效，不需要在每个项目重新配置
- 语音文件在 `setup.sh` 时一次性生成到 `sounds/` 目录

## 项目管理

```bash
# 扫描目录下所有 git 仓库
bash scripts/scan-projects.sh ~/Documents/code

# 手动添加项目
bash scripts/add-project.sh my-app ~/code/my-app app 前端

# 查看项目列表
bash scripts/welcome.sh
```

## 通知面板（Tauri App）

菜单栏托盘应用，实时展示项目状态和通知。

- 左键点击托盘图标 → 显示面板
- 关闭窗口 × → 隐藏到托盘（不退出）
- 右键托盘 → 退出
- 支持项目搜索（按名称/描述/路径模糊匹配）
- **用量统计** — 按项目查看 token 消耗、会话数、模型分布

`setup.sh` 首次运行会自动编译 release 版本（约 2-3 分钟），之后每次启动直接运行二进制，秒开。编译产物是本机架构（ARM/x86），不会提交到 git。

手动编译/重新编译：

```bash
bash scripts/build-app.sh
```

## 浏览器自动化

Claude in Chrome（视觉引擎）+ chrome-devtools-mcp（数据引擎）双引擎协同，连接同一个 Chrome 浏览器。

**前置要求：**
- Chrome >= 144（支持 autoConnect 模式）
- Claude in Chrome 扩展已安装
- Chrome remote debugging 已启用

```bash
# 一键配置（安装 skill + 配置 MCP + 检查 Chrome 环境）
bash scripts/setup-browser.sh
```

配置完成后：
1. Chrome 地址栏输入 `chrome://inspect/#remote-debugging`，点击 Enable（一次性操作）
2. 重启 Claude Code 会话

## 故障排查

### 通知不工作

```bash
# 1. 检查 hook 是否已注入
cat ~/.claude/settings.json | python3 -m json.tool | grep -A5 hub-hook

# 2. 手动触发测试（应该听到语音 + 看到桌面通知）
bash scripts/hub-hook-stop.sh

# 3. 检查 terminal-notifier
which terminal-notifier || echo "未安装，运行: brew install terminal-notifier"
```

### iTerm2 标签页不显示

- 确认 iTerm2 设置：**Settings → General → tmux** → 两个选项都勾选（见上方 "配置 iTerm2" 章节）
- 确认 tmux 版本：`tmux -V`（需要 >= 3.0）
- 手动测试：在 iTerm2 中执行 `tmux -CC new -s test`，应该弹出新的原生标签页

### osascript 权限报错

```
Not authorized to send Apple events to iTerm2
```

1. 打开 **系统设置** → **隐私与安全性** → **自动化**
2. 找到 Terminal（或 iTerm2），勾选允许控制
3. 手动验证：`osascript -e 'tell application "iTerm2" to activate'`

### 托盘 app 编译失败

```bash
# 检查 Xcode CLT
xcode-select -p

# 清理后重新编译
cd app/src-tauri && cargo clean && cargo build --release

# 首次编译需下载约 2GB 依赖，确保网络通畅
```

### 浏览器双引擎连不上

```bash
# 检查 Chrome 版本（需要 >= 144）
/Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome --version

# 检查远程调试端口
curl -s localhost:9222/json/version

# 检查 MCP 配置（应包含 --autoConnect）
claude mcp get chrome-devtools
```

## 目录结构

```
claude-hub/
├── CLAUDE.md                  # Hub 行为规范（Claude 读取此文件决定行为）
├── projects.yaml.example      # 项目配置模板
├── app/                       # 通知面板（Tauri v2）
│   ├── src/                   # 前端（HTML + JS）
│   └── src-tauri/             # 后端（Rust）
│       └── src/
│           ├── main.rs        # 入口 + Tauri 命令
│           ├── watcher.rs     # 文件监听（/tmp/hub-signals/events/）
│           ├── projects.rs    # 项目管理 + tmux 集成
│           └── usage.rs       # 用量统计（解析 Claude 日志）
├── scripts/
│   ├── setup.sh               # 一键初始化（hooks + 语音 + 编译）
│   ├── setup-browser.sh       # 浏览器环境配置
│   ├── build-app.sh           # 编译托盘 app（检查环境 + release 构建）
│   ├── cc.sh                  # 一键启动（托盘 app + 调度中心）
│   ├── scan-projects.sh       # 扫描目录发现项目
│   ├── add-project.sh         # 添加项目
│   ├── welcome.sh             # 项目列表展示
│   ├── project-menu.sh        # tmux 窗口菜单
│   ├── hub-hook-stop.sh       # Stop hook（做完通知）
│   ├── hub-hook-permission.sh # Notification hook（授权通知）
│   ├── hub-run.sh             # 命令包装（带信号）
│   └── hub-notify.sh          # 手动通知
├── skills/
│   ├── tmux-hub/              # 终端调度 skill
│   ├── browser-auto/          # 浏览器自动化 skill
│   └── lanhu-design-viewer/   # 设计稿查看 skill
└── sounds/                    # 语音文件（setup.sh 自动生成）
    ├── done1~5.aiff           # "搞定了" 等 5 种完成语音
    └── auth1~3.aiff           # "需要授权" 等 3 种提示语音
```

## License

MIT
