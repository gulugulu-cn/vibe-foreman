# Claude Hub

Claude Code 本地开发调度中心。用一个 Claude 窗口管理所有项目。

## 功能

- **tmux 多项目管理** — 每个项目一个 tmux 窗口，iTerm2 标签页体验
- **全局通知** — 任何 Claude 做完事 → 桌面弹窗 + 语音提醒
- **权限通知** — 任何 Claude 等授权 → 立即提醒你去操作
- **项目发现** — 扫描目录自动生成项目清单
- **浏览器自动化** — Claude in Chrome + DevTools 双引擎协同

## 快速开始

```bash
# 1. 克隆
git clone https://github.com/hengjun-dev/claude-hub.git
cd claude-hub

# 2. 初始化（注入全局 hooks + 生成语音文件）
bash scripts/setup.sh

# 3. 添加你的项目（二选一）
bash scripts/scan-projects.sh ~/Documents/code    # 自动扫描
# 或手动编辑
cp projects.yaml.example projects.yaml
vim projects.yaml

# 4. 浏览器自动化环境（可选）
bash scripts/setup-browser.sh

# 5. 启动
claude
```

启动后 Claude 会自动：拉起通知面板 → 显示项目列表 → 检查 tmux → 报告就绪。

## 前置条件

- macOS（Apple Silicon / Intel 均可）+ iTerm2
- [tmux](https://github.com/tmux/tmux) — `brew install tmux`
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code)
- Xcode Command Line Tools — `xcode-select --install`
- Rust 工具链 — `setup.sh` 首次运行时**自动安装**，无需手动操作

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
