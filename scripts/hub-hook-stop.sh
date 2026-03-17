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

# 随机选一条完成语（桌面通知用）
MESSAGES=(
  "${NAME} 搞定了，来看看"
  "${NAME} 干完了，等你验收"
  "${NAME} 这边好了"
  "${NAME} 完事儿了"
  "${NAME} 做好了，请过目"
)
IDX=$((RANDOM % ${#MESSAGES[@]}))
MSG="${MESSAGES[$IDX]}"

# 桌面通知
osascript -e "display notification \"${MSG}\" with title \"🤖 调度中心\" sound name \"Glass\"" 2>/dev/null

# 语音播报（预生成的音频文件，不会被杀）
DONE_FILES=("$SOUNDS_DIR"/done*.aiff)
if [ ${#DONE_FILES[@]} -gt 0 ]; then
  SOUND="${DONE_FILES[$((RANDOM % ${#DONE_FILES[@]}))]}"
  afplay "$SOUND" 2>/dev/null
fi

# hub tmux 信号（供程序化监控）
if [ "$TMUX_SESSION" = "hub" ] && [ -n "$NAME" ]; then
  SIGNAL_DIR="/tmp/hub-signals"
  mkdir -p "$SIGNAL_DIR"
  echo "$(date '+%H:%M:%S') $NAME done" > "$SIGNAL_DIR/hub-${NAME}-stop.result"
  tmux wait-for -S "hub-${NAME}-stop" 2>/dev/null
fi
