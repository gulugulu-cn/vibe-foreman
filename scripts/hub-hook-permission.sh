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

# 随机选一条提醒语（桌面通知用）
MESSAGES=(
  "${NAME} 需要你授权"
  "${NAME} 在等你点确认"
  "${NAME} 卡住了，需要你批准"
  "快去 ${NAME}，Claude 在等你"
)
MSG="${MESSAGES[$((RANDOM % ${#MESSAGES[@]}))]}"

# 桌面通知（不同声音区分）
osascript -e "display notification \"${MSG}\" with title \"⚠️ 需要授权\" sound name \"Basso\"" 2>/dev/null

# 语音播报（预生成的音频文件）
AUTH_FILES=("$SOUNDS_DIR"/auth*.aiff)
if [ ${#AUTH_FILES[@]} -gt 0 ]; then
  SOUND="${AUTH_FILES[$((RANDOM % ${#AUTH_FILES[@]}))]}"
  afplay "$SOUND" 2>/dev/null
fi
