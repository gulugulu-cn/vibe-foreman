#!/bin/bash
# Notification hook - Claude 需要授权时通知用户
# 全局生效，零配置。

# 获取项目名
if [ -n "$TMUX" ]; then
  NAME=$(tmux display-message -p '#W' 2>/dev/null)
fi
if [ -z "$NAME" ]; then
  NAME=$(git rev-parse --show-toplevel 2>/dev/null | xargs basename 2>/dev/null)
fi
NAME="${NAME:-$(basename "$PWD" 2>/dev/null)}"

HUB_DIR="$HOME/Documents/code/claude-hub"
SOUNDS_DIR="$HUB_DIR/sounds"
SIGNAL_DIR="/tmp/hub-signals"
EVENTS_DIR="$SIGNAL_DIR/events"

# 随机选一条提醒语
MESSAGES=(
  "需要你授权"
  "在等你点确认"
  "卡住了，需要你批准"
  "Claude 在等你"
)
MSG="${MESSAGES[$((RANDOM % ${#MESSAGES[@]}))]}"

# 写 JSON 事件文件（供 Tauri app 读取）
mkdir -p "$EVENTS_DIR"
cat > "$EVENTS_DIR/$(date +%s%N 2>/dev/null || date +%s).json" << EOF
{
  "type": "permission",
  "project": "${NAME}",
  "message": "${MSG}",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%H:%M:%S)"
}
EOF

# Fallback: 如果 Tauri app 没运行，用 osascript
if ! pgrep -x "Claude Hub" >/dev/null 2>&1 && ! pgrep -x "claude-hub" >/dev/null 2>&1; then
  osascript -e "display notification \"${NAME} ${MSG}\" with title \"⚠️ 需要授权\" sound name \"Basso\"" 2>/dev/null
  AUTH_FILES=("$SOUNDS_DIR"/auth*.aiff)
  if [ ${#AUTH_FILES[@]} -gt 0 ]; then
    SOUND="${AUTH_FILES[$((RANDOM % ${#AUTH_FILES[@]}))]}"
    afplay "$SOUND" 2>/dev/null
  fi
fi
