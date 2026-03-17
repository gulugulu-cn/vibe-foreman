#!/bin/bash
# hub-run: 在 hub 子窗口中执行命令并自动发送完成信号
# 用法: hub-run <channel> <command...>
#
# 示例:
#   hub-run erp-build-123 npm run build
#   hub-run deploy-456 docker compose up -d

CHANNEL="$1"
if [ -z "$CHANNEL" ] || [ $# -lt 2 ]; then
  echo "用法: hub-run <channel> <command...>"
  echo "示例: hub-run my-channel npm run build"
  exit 1
fi
shift

SIGNAL_DIR="/tmp/hub-signals"
mkdir -p "$SIGNAL_DIR"

# 执行命令
"$@"
EXIT_CODE=$?

# 写结果
echo "$EXIT_CODE" > "$SIGNAL_DIR/$CHANNEL.result"

# 发送 tmux 信号
tmux wait-for -S "$CHANNEL" 2>/dev/null

exit $EXIT_CODE
