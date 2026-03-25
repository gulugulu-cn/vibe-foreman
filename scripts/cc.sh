#!/bin/bash
# cc - Claude Hub 一键启动
# 安装: 在 ~/.zshrc 中添加 alias cc="bash ~/Documents/code/claude-hub/scripts/cc.sh"
#
# 做两件事：
# 1. 启动 Claude Hub 托盘 app（如果没在跑）
# 2. 在 claude-hub 目录启动 claude（调度中心）

HUB_DIR="$HOME/Documents/code/claude-hub"
APP_RELEASE="$HUB_DIR/app/src-tauri/target/release/claude-hub"

# 1. 启动托盘 app
if ! pgrep -f "claude-hub" >/dev/null 2>&1; then
  if [ -f "$APP_RELEASE" ]; then
    "$APP_RELEASE" &
    disown
    echo "✓ Claude Hub 托盘已启动"
  else
    echo "⚠ 未找到编译产物，请先执行: cd $HUB_DIR/app && cargo build --release"
  fi
else
  echo "✓ Claude Hub 托盘已在运行"
fi

# 2. 启动 Claude 调度中心
cd "$HUB_DIR"
exec claude
