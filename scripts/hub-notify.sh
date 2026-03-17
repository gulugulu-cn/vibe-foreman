#!/bin/bash
# hub-notify: 手动通知 hub 任务完成
# 用法: hub-notify [channel] [exit_code]
#
# 不传 channel 则列出等待中的信号
# 不传 exit_code 默认 0

CHANNEL="${1:-$HUB_CHANNEL}"
EXIT_CODE="${2:-0}"
SIGNAL_DIR="/tmp/hub-signals"

if [ -z "$CHANNEL" ]; then
  echo "等待中的 channel:"
  if [ -d "$SIGNAL_DIR" ]; then
    ls "$SIGNAL_DIR"/*.result 2>/dev/null | sed 's|.*/||;s|\.result||' | while read f; do
      echo "  $f (exit: $(cat "$SIGNAL_DIR/$f.result"))"
    done
  fi
  echo ""
  echo "用法: hub-notify <channel> [exit_code]"
  exit 1
fi

mkdir -p "$SIGNAL_DIR"
echo "$EXIT_CODE" > "$SIGNAL_DIR/$CHANNEL.result"
tmux wait-for -S "$CHANNEL" 2>/dev/null
echo "已通知 hub: $CHANNEL (exit: $EXIT_CODE)"
