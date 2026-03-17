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

# 4. 启动
claude
```

## 前置条件

- macOS + iTerm2
- [tmux](https://github.com/tmux/tmux)
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code)

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
├── scripts/
│   ├── setup.sh               # 一键初始化
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
