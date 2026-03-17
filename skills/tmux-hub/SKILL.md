---
name: tmux-hub
description: "Terminal dispatch center. Use when user wants to open a project, run tasks in other terminals, monitor build/test results, or switch between projects. Manages tmux windows as iTerm2 tabs from a central conversation window."
---

# 终端调度中心

你是核心窗口。通过 tmux 管理其他项目窗口，用户和你都能操作这些窗口。

## 项目路径映射

从 `projects.yaml` 读取项目清单。查找规则：
1. 精确匹配 `name` 字段
2. 匹配 `aliases` 列表
3. 在 `~/Documents/code/` 下模糊匹配目录名

管理命令：
- 添加项目: `bash scripts/add-project.sh <name> <path> [aliases...]`
- 扫描目录: `bash scripts/scan-projects.sh [目录]`

## 流程

### 1. 初始化 hub session

不要在启动时创建 session。等用户请求打开项目时再创建。

### 2. 打开项目

用户说"我要开发 {project}"时：

```bash
# 查找路径
PROJECT_PATH=~/Documents/code/{目录名}

# hub session 不存在 → 用第一个项目创建（不要创建多余的 control 窗口）
tmux has-session -t hub 2>/dev/null || tmux new-session -d -s hub -n {name} -c {PROJECT_PATH}

# hub session 已存在 → 检查窗口是否存在，不存在则添加
tmux list-windows -t hub -F '#{window_name}' | grep -q {name} || tmux new-window -t hub -n {name} -c {PROJECT_PATH}

# 如果没有 tmux -CC 客户端连接 → 自动在当前窗口新标签页打开
if ! tmux list-clients -t hub 2>/dev/null | grep -q "attached"; then
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
fi
```

告知用户："已打开 {project}"

### 3. 在其他窗口执行命令

```bash
# 向目标窗口发送命令
tmux send-keys -t hub:{name} '{command}' Enter
```

### 4. 异步执行并等待结果

当需要等待任务完成（构建、测试、部署等）时，有两种方式：

#### 方式 A: hub-run 包装（推荐，发到终端窗口）

```bash
# Step 1: 生成唯一 channel
CHANNEL="{name}-$(date +%s)"

# Step 2: 用 hub-run 发送命令（自动处理信号）
tmux send-keys -t hub:{name} "bash ~/Documents/code/claude-hub/scripts/hub-run.sh $CHANNEL {command}" Enter

# Step 3: 后台等待（run_in_background=true）
tmux wait-for $CHANNEL

# Step 4: 读取结果
cat /tmp/hub-signals/$CHANNEL.result  # 0=成功, 非0=失败
```

#### 方式 B: 环境变量（发到子窗口 Claude 实例）

```bash
# Step 1: 生成唯一 channel
CHANNEL="{name}-$(date +%s)"

# Step 2: 设置环境变量（子窗口 Claude 的 PostToolUse hook 会自动发信号）
tmux send-keys -t hub:{name} "export HUB_CHANNEL=$CHANNEL" Enter

# Step 3: 发送实际命令（子窗口 Claude 执行 Bash 后 hook 自动通知）
tmux send-keys -t hub:{name} "{command}" Enter

# Step 4: 后台等待
tmux wait-for $CHANNEL
```

**用 Bash 工具的 `run_in_background=true` 执行等待步骤**，Claude 不会被阻塞。

### 5. 任务完成通知

后台任务完成后：

```bash
# 1. 读取退出码
EXIT_CODE=$(cat /tmp/hub-signals/$CHANNEL.result 2>/dev/null || echo "unknown")

# 2. 捕获窗口输出
tmux capture-pane -t hub:{name} -p -S -30

# 3. 发送 macOS 通知 + 语音播报
if [ "$EXIT_CODE" = "0" ]; then
  osascript -e 'display notification "{name} 任务完成" with title "调度中心" sound name "Glass"'
  say "{name} 任务完成"
else
  osascript -e 'display notification "{name} 任务失败 (exit: '$EXIT_CODE')" with title "调度中心" sound name "Basso"'
  say "{name} 任务失败"
fi
```

### 6. 读取其他窗口状态

随时可以查看任意窗口的当前内容：

```bash
# 查看最近 30 行输出
tmux capture-pane -t hub:{name} -p -S -30

# 列出所有窗口
tmux list-windows -t hub -F '#{window_index}: #{window_name} #{window_active}'
```

### 7. 切换用户焦点

用户说"切到 acme-erp"时：

```bash
tmux select-window -t hub:{name}
```

在 tmux -CC 模式下，iTerm2 会自动切换到对应标签页。

### 8. 会话恢复

Claude Code 重启后，检查之前的 session：

```bash
# 检查 hub session
tmux has-session -t hub 2>/dev/null && echo "hub 存在"

# 列出所有窗口
tmux list-windows -t hub -F '#{window_name}'

# 查看每个窗口最近状态
for w in $(tmux list-windows -t hub -F '#{window_name}'); do
  echo "=== $w ==="
  tmux capture-pane -t hub:$w -p -S -5
done
```

## 常用操作速查

| 用户说 | Claude 执行 |
|--------|------------|
| "开发 acme-erp" | `tmux new-window -t hub -n acme-erp -c ~/Documents/code/acme-admin` |
| "在 acme-erp 跑构建" | `tmux send-keys -t hub:acme-erp 'npm run build' Enter` + 后台等待 |
| "acme-erp 什么状态" | `tmux capture-pane -t hub:acme-erp -p -S -20` |
| "切到 shopify" | `tmux select-window -t hub:shopify` |
| "关掉 game" | `tmux kill-window -t hub:game` |
| "现在有哪些窗口" | `tmux list-windows -t hub -F '#{window_name}'` |
| "继续" | 在对应窗口执行下一步命令 |

## 命令模板

### 带完成通知的异步任务

```bash
# 发送命令（Bash 工具，同步）
CHANNEL="erp-build-$(date +%s)"
tmux send-keys -t hub:acme-erp "bash ~/Documents/code/claude-hub/scripts/hub-run.sh $CHANNEL npm run build" Enter

# 等待完成（Bash 工具，run_in_background=true）
tmux wait-for $CHANNEL
# 信号到达后读取退出码
EXIT_CODE=$(cat /tmp/hub-signals/$CHANNEL.result)
```

### 人工通知 hub

子窗口用户可以手动通知 hub：

```bash
# 在子窗口运行
hub-notify <channel>          # 通知指定 channel
hub-notify                    # 列出等待中的 channel
```

## 限制

- **10 分钟超时**：`run_in_background` 最大 600 秒。Docker build 等长任务可能超时，需要分段等待。
- **不支持交互式命令**：vim、less、密码输入等需要用户自己去那个窗口操作。
- **首次连接**：通过 osascript 自动打开 iTerm2 新窗口执行 `tmux -CC attach -t hub`。
- **通知不能自动跳转**：macOS 通知点击不会自动切到对应窗口（除非安装 terminal-notifier）。
