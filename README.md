# Claude Hub

Claude Code 本地开发调度中心。用一个 Claude 窗口管理所有项目。

## 功能

- **tmux 多项目管理** — 每个项目一个 tmux 窗口，iTerm2 标签页体验
- **全局通知** — 任何 Claude 做完事 → 桌面弹窗 + 语音提醒
- **权限通知** — 任何 Claude 等授权 → 立即提醒你去操作
- **项目发现** — 扫描目录自动生成项目清单
- **用量统计** — 按项目查看 token 消耗、会话数、模型分布
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

### 2. 配置 iTerm2（关键！）

项目依赖 `tmux -CC` 模式，让 tmux 窗口显示为 iTerm2 原生标签页。需要配置：

1. 打开 iTerm2 → **Settings** (⌘,)
2. **General → tmux**：
   - ✅ "Open tmux windows as native tabs in a new window"（tmux 窗口显示为标签页）
   - ✅ "Automatically bury the tmux client session after connecting"（连接后自动隐藏控制会话）

> 不配置这两项的话，tmux 窗口不会以标签页形式展示，体验会很差。

### 3. 克隆并初始化

```bash
git clone https://github.com/hengjun-dev/claude-hub.git
cd claude-hub

# 一键初始化（注入全局 hooks + 生成语音 + 自动编译托盘 app）
# 首次编译约 2-3 分钟，Rust 环境不存在会自动安装
bash scripts/setup.sh
```

### 4. 添加项目

```bash
# 自动扫描目录下所有 git 仓库
bash scripts/scan-projects.sh ~/Documents/code

# 或手动编辑
cp projects.yaml.example projects.yaml
vim projects.yaml
```

### 5. 配置启动别名（推荐）

```bash
echo 'alias cc="bash ~/Documents/code/claude-hub/scripts/cc.sh"' >> ~/.zshrc
source ~/.zshrc
```

之后只需输入 `cc` 即可一键启动调度中心（自动拉起托盘 app + 启动 Claude）。

### 6. 浏览器自动化（可选）

```bash
bash scripts/setup-browser.sh
```

配置完成后还需在 Chrome 地址栏输入 `chrome://inspect/#remote-debugging`，点击 Enable。

### 7. 启动

```bash
cc          # 如果配了别名
# 或
claude      # 在 claude-hub 目录直接启动
```

启动后 Claude 会自动：拉起通知面板 → 显示项目列表 → 检查 tmux → 报告就绪。

## 前置条件汇总

| 依赖 | 用途 | 安装方式 |
|------|------|---------|
| macOS + iTerm2 | 终端环境 | 手动安装 |
| tmux | 多窗口管理 | `brew install tmux` |
| terminal-notifier | 桌面通知弹窗 | `brew install terminal-notifier` |
| Node.js | Claude Code CLI + MCP 工具 | `brew install node` |
| Claude Code CLI | Claude 命令行 | `npm i -g @anthropic-ai/claude-code` |
| Xcode CLT | 编译 Rust 代码 | `xcode-select --install` |
| Rust | 编译托盘 app | `setup.sh` **自动安装** |

> Apple Silicon（M1/M2/M3/M4）和 Intel Mac 均支持，托盘 app 在本机编译，无架构兼容问题。

## 工作原理

```
你 ← 桌面通知 + 语音 ← 全局 Stop hook
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

也可以在`~/.zshrc`中添加别名一键启动调度中心（含自动拉起托盘 app）：

```bash
alias cc="bash ~/Documents/code/claude-hub/scripts/cc.sh"
```

## 浏览器自动化

Claude in Chrome（视觉引擎）+ chrome-devtools-mcp（数据引擎）双引擎协同，连接同一个 Chrome 浏览器。

```bash
# 一键配置（安装 skill + 配置 MCP + 检查 Chrome 环境）
bash scripts/setup-browser.sh
```

配置完成后需要：
1. Chrome 地址栏输入 `chrome://inspect/#remote-debugging`，点击 Enable
2. 重启 Claude Code 会话

## 全局 Hooks

`setup.sh` 会在 `~/.claude/settings.json` 中注入两个全局 hook：

| Hook | 触发时机 | 效果 |
|------|---------|------|
| **Stop** | Claude 完成一轮回复 | 桌面弹窗 + 语音"搞定了" |
| **Notification** | Claude 需要用户操作 | 桌面弹窗 + 语音"需要授权" |

所有 Claude 实例自动生效，零配置。

## 目录结构

```
claude-hub/
├── CLAUDE.md                  # Hub 行为规范
├── projects.yaml.example      # 项目配置模板
├── app/                       # 通知面板（Tauri v2）
│   ├── src/                   # 前端（HTML + JS）
│   └── src-tauri/             # 后端（Rust）
├── scripts/
│   ├── setup.sh               # 一键初始化（含自动编译）
│   ├── setup-browser.sh       # 浏览器环境配置
│   ├── build-app.sh           # 编译托盘 app（检查环境 + release 构建）
│   ├── cc.sh                  # 一键启动（托盘 app + 调度中心）
│   ├── scan-projects.sh       # 扫描目录发现项目
│   ├── add-project.sh         # 添加项目
│   ├── welcome.sh             # 项目列表展示
│   ├── project-menu.sh        # tmux 窗口菜单
│   ├── hub-hook-stop.sh       # Stop hook（做完通知）
│   ├── hub-hook-permission.sh # Notification hook（授权通知）
│   ├── hub-run.sh             # 命令包装（自动信号）
│   └── hub-notify.sh          # 手动通知
└── skills/
    ├── tmux-hub/              # 终端调度
    ├── browser-auto/          # 浏览器自动化
    └── lanhu-design-viewer/   # 设计稿查看
```

## License

MIT
