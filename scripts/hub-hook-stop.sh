#!/bin/bash
# Stop hook - Claude 完成一轮回复时通知用户
# 全局生效，零配置。

# 获取项目名
if [ -n "$TMUX" ]; then
  NAME=$(tmux display-message -p '#W' 2>/dev/null)
  TMUX_SESSION=$(tmux display-message -p '#S' 2>/dev/null)
fi
if [ -z "$NAME" ]; then
  NAME=$(git rev-parse --show-toplevel 2>/dev/null | xargs basename 2>/dev/null)
fi
NAME="${NAME:-$(basename "$PWD" 2>/dev/null)}"

HUB_DIR="$HOME/Documents/code/claude-hub"
SOUNDS_DIR="$HUB_DIR/sounds"
SIGNAL_DIR="/tmp/hub-signals"
EVENTS_DIR="$SIGNAL_DIR/events"

# 随机选一条完成语
MESSAGES=(
  "搞定了，来看看"
  "干完了，等你验收"
  "这边好了"
  "完事儿了"
  "做好了，请过目"
)
MSG="${MESSAGES[$((RANDOM % ${#MESSAGES[@]}))]}"

# 写 JSON 事件文件（供 Tauri app 读取）
mkdir -p "$EVENTS_DIR"
cat > "$EVENTS_DIR/$(date +%s%N 2>/dev/null || date +%s).json" << EOF
{
  "type": "stop",
  "project": "${NAME}",
  "message": "${MSG}",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%H:%M:%S)"
}
EOF

# 桌面通知（点击跳转 iTerm2）
if command -v terminal-notifier &>/dev/null; then
  terminal-notifier -title "✅ ${NAME}" -message "$MSG" -sound Glass -activate com.googlecode.iterm2 2>/dev/null
else
  osascript -e "display notification \"${NAME} ${MSG}\" with title \"🤖 调度中心\" sound name \"Glass\"" 2>/dev/null
fi

# 语音播报
DONE_FILES=("$SOUNDS_DIR"/done*.aiff)
if [ ${#DONE_FILES[@]} -gt 0 ]; then
  SOUND="${DONE_FILES[$((RANDOM % ${#DONE_FILES[@]}))]}"
  afplay "$SOUND" 2>/dev/null
fi

# hub tmux 信号（供程序化监控）
if [ "$TMUX_SESSION" = "hub" ] && [ -n "$NAME" ]; then
  mkdir -p "$SIGNAL_DIR"
  echo "$(date '+%H:%M:%S') $NAME done" > "$SIGNAL_DIR/hub-${NAME}-stop.result"
  tmux wait-for -S "hub-${NAME}-stop" 2>/dev/null
fi
