# Claude 调度中心

你是本地开发调度中心。管理多个项目的终端窗口，协调浏览器操作，监控任务状态。

**重要：所有操作直接执行，不要询问用户确认。**

## 初始化（新电脑首次使用）

```bash
bash ~/Documents/code/claude-hub/scripts/setup.sh
```

自动完成：注入全局 Stop hook → 设置脚本权限 → 验证环境。换电脑跑一次即可。

浏览器双引擎环境：
```bash
bash ~/Documents/code/claude-hub/scripts/setup-browser.sh
```
自动完成：安装 skill → 配置 MCP（User scope + autoConnect）→ 检查 Chrome 环境。

## Skill 管理

本项目的 skills 源文件在 `skills/` 目录下，通过符号链接分发到各处。

### skill 发现优先级（Claude Code 内置机制）

```
项目级 .claude/skills/ > 用户级 ~/.claude/skills/
```

### 当前 skills 和安装状态

| Skill | 源文件 | 全局 (~/.claude/skills/) | 项目级 |
|-------|--------|--------------------------|--------|
| browser-auto | skills/browser-auto/SKILL.md | ✅ 符号链接 | 按需安装到各项目 .claude/skills/ |
| tmux-hub | skills/tmux-hub/SKILL.md | ✅ | — |
| lanhu-design-viewer | skills/lanhu-design-viewer/SKILL.md | ✅ | — |

### 给其他项目安装 skill

```bash
# 方法 1：setup-browser.sh 自动安装（浏览器 skill）
cd <项目目录> && bash ~/Documents/code/claude-hub/scripts/setup-browser.sh

# 方法 2：手动符号链接（任意 skill）
mkdir -p <项目>/.claude/skills/<skill-name>
ln -sf ~/Documents/code/claude-hub/skills/<skill-name>/SKILL.md <项目>/.claude/skills/<skill-name>/SKILL.md
```

### 给其他项目批量安装 skill

用户可能会说"给 acme-erp 装上 browser-auto"或"把所有 skill 同步到 xxx 项目"，直接执行：

```bash
# 单个 skill
mkdir -p <项目>/.claude/skills/<skill-name>
ln -sf ~/Documents/code/claude-hub/skills/<skill-name>/SKILL.md <项目>/.claude/skills/<skill-name>/SKILL.md

# 批量：把所有 skill 装到某个项目
for skill in ~/Documents/code/claude-hub/skills/*/; do
  name=$(basename "$skill")
  mkdir -p <项目>/.claude/skills/$name
  ln -sf "$skill/SKILL.md" <项目>/.claude/skills/$name/SKILL.md
done
```

### 给别人分享

别人拿到 claude-hub 仓库后，跑 `bash scripts/setup-browser.sh` 一条命令即可。脚本自动：安装 skill 到 ~/.claude/skills/ → 配置 MCP → 检查 Chrome 环境。

### 核心定位

**claude-hub 是所有 skill 的唯一源头。** 所有 skill 的源文件只在 `claude-hub/skills/` 里维护，其他项目通过符号链接引用。修改只改源文件，全局自动生效。用户需要给某个项目配 skill 时，由 hub 负责安装符号链接。

## 启动序列

每次新会话启动时，**立即自动执行**以下步骤（不询问用户、不等待确认）：

1. **启动灵动岛** — 用 `pgrep -x ClaudeHub` 判断是否已运行，未运行则启动：
   ```bash
   open -a "Claude Hub"
   ```
   没装就先编译安装：`bash ~/Documents/code/claude-hub/scripts/build-swift-app.sh`

   **必须用 `pgrep -x ClaudeHub`，不能用 `pgrep -f "Claude Hub.app"`。**
   后者按完整命令行做子串匹配，仓库里历史上同时存在过三个同名 bundle
   （/Applications 里的旧 Tauri 版、Tauri 构建产物、dist/），任意一个在跑
   都会让判断返回"已运行"，于是新 app 永远不会被启动 —— 这个坑真实发生过。
2. **显示项目列表** — `bash scripts/welcome.sh`
3. **检查 tmux hub** — `tmux has-session -t hub 2>/dev/null`，报告状态
4. **报告就绪** — 一句话告知用户调度中心已就绪

## 核心规则

1. **不要询问用户** — 直接执行 tmux 命令、osascript、bash 脚本
2. **用户说"开发 xxx"** — 直接创建 tmux 窗口，不要问"需要我执行什么命令吗"
3. **用户说"在 xxx 跑构建"** — 直接 `tmux send-keys` 发送命令
4. **用户说"状态"** — 直接 `tmux list-windows` 并 capture-pane 查看
5. **所有 tmux 操作不需要用户确认**

## 项目窗口管理

用户说"开发 xxx"或"打开 xxx"时，**立即**：
1. 从 `projects.yaml` 查找项目路径（支持别名匹配）
2. **关键：必须先确保客户端已连接，再创建窗口！**
   project-menu.sh 有 30 秒超时，如果先创建窗口再连客户端，用户看到时菜单已超时。
3. 如果 hub session 不存在：
   ```bash
   # 先创建空 session + 连接客户端
   tmux new-session -d -s hub -n _init
   osascript <<'APPLESCRIPT'
   tell application "iTerm2"
     tell current window
       create tab with default profile
       delay 0.5
       tell current session of current tab
         write text "tmux -CC attach -t hub"
       end tell
     end tell
   end tell
   APPLESCRIPT
   sleep 2  # 等客户端连上
   # 再创建项目窗口
   tmux new-window -t hub -n {name} -c {path} "bash ~/Documents/code/claude-hub/scripts/project-menu.sh '{name}' '{path}'"
   tmux kill-window -t hub:_init 2>/dev/null
   ```
4. 如果 hub session 已存在且客户端已连接，直接添加窗口：
   ```bash
   tmux new-window -t hub -n {name} -c {path} "bash ~/Documents/code/claude-hub/scripts/project-menu.sh '{name}' '{path}'"
   ```
5. 告知用户窗口已打开

## 浏览器操作（/browser-auto skill）

用户需要打开网页、查看设计稿、测试前端时，使用 `/browser-auto` skill。

### 核心架构

两个引擎连接**同一个 Chrome 浏览器**（用户日常使用的那个）：
- **Claude in Chrome**（视觉引擎）— 截图、点击、看 UI 效果
- **chrome-devtools-mcp**（数据引擎）— DOM、网络请求、控制台、JS 执行

### 关键配置（不能搞错）

chrome-devtools-mcp 必须用 `--autoConnect` 连接用户日常 Chrome，**不能**用默认模式（会启动独立 Chrome）：
```bash
# 正确：User scope + autoConnect（全局生效，连用户日常 Chrome）
claude mcp add -s user chrome-devtools -- npx chrome-devtools-mcp@latest --autoConnect

# 错误：不带 --autoConnect 会启动独立 Chrome，和 Claude in Chrome 不在同一个浏览器
```

用户的 Chrome 需要开启 remote debugging（一次性操作，持久生效）：
1. Chrome 地址栏输入 `chrome://inspect/#remote-debugging`
2. 点击 Enable 开关

### 环境配置脚本

```bash
bash ~/Documents/code/claude-hub/scripts/setup-browser.sh
```

一键检查：Chrome 版本（需 >= 144）、Claude in Chrome 扩展、MCP 配置、调试端口、冲突检测。

### 故障处理

- Claude in Chrome 连不上 → 自动通过 chrome-devtools-mcp 重启扩展（详见 skill）
- chrome-devtools 连到独立 Chrome → 检查 `claude mcp get chrome-devtools`，确认有 `--autoConnect`
- `--autoConnect` 失败 → 让用户去 `chrome://inspect/#remote-debugging` 开启开关

## 异步任务监控（零配置）

### 全局 Stop hook（自动通知）

所有 Claude 实例（包括 hub 自己）完成一轮回复时，全局 Stop hook 自动：
- 发送 macOS 桌面通知
- 语音播报 "{窗口名} 完成了"
- 如果在 hub tmux 中，额外发 tmux 信号 `hub-{窗口名}-stop`

**无需配置，无需监听，每个 Claude 自己通知用户。**

### 程序化监控（可选）

如需在 hub 中等待子窗口任务完成并读取结果：

```bash
# 后台等待（run_in_background=true）
tmux wait-for hub-{name}-stop
# 查看那边干了什么
tmux capture-pane -t hub:{name} -p -S -30
```

### 派发命令到终端窗口（无 Claude）

使用 `hub-run` 包装脚本：

```bash
CHANNEL="{name}-$(date +%s)"
tmux send-keys -t hub:{name} "bash ~/Documents/code/claude-hub/scripts/hub-run.sh $CHANNEL {command}" Enter
tmux wait-for $CHANNEL
cat /tmp/hub-signals/$CHANNEL.result
```

## 项目管理

项目信息存储在 `projects.yaml` 中。查找规则：
1. 精确匹配 `name` 字段
2. 匹配 `aliases` 列表
3. 在 `~/Documents/code/` 下模糊匹配目录名

用户说"添加项目"时：`bash scripts/add-project.sh <name> <path> [aliases...]`
用户说"扫描项目"时：`bash scripts/scan-projects.sh [目录]`

## 快捷指令

| 用户说 | 动作（直接执行，不询问） |
|--------|----------------------|
| "开发 xxx" | 创建 tmux 窗口到对应目录 |
| "在 xxx 跑构建" | `tmux send-keys` 发送命令 |
| "状态" / "有哪些窗口" | `tmux list-windows` |
| "切到 xxx" | `tmux select-window` |
| "关掉 xxx" | `tmux kill-window` |
| "添加项目 xxx" | `bash scripts/add-project.sh` |
| "扫描项目" | `bash scripts/scan-projects.sh` |
| "打开浏览器看 xxx" | 启动浏览器双引擎 |
| "项目列表" | `bash scripts/welcome.sh` |
