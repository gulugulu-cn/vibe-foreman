#!/bin/bash
# cc - Claude Hub 一键启动
# 安装: 在 ~/.zshrc 中添加 alias cc="bash ~/Documents/code/claude-hub/scripts/cc.sh"
#
# 做两件事：
# 1. 启动 Claude Hub 托盘 app（如果没在跑）
# 2. 在 claude-hub 目录启动 claude（调度中心）

HUB_DIR="$HOME/Documents/code/claude-hub"
APP_PATH="/Applications/Claude Hub.app"

# 1. 启动托盘 app
#
# 用 `pgrep -x ClaudeHub` 判断存活，**不能**用 `pgrep -f "Claude Hub"`：
# 后者会匹配到任何路径里含这个串的进程（历史上仓库里同时存在过三个同名 bundle），
# 于是明明没在跑也会被判成"已运行"，app 永远起不来。-x 精确匹配进程名。
if ! pgrep -x ClaudeHub >/dev/null 2>&1; then
  if [ -d "$APP_PATH" ]; then
    open -a "$APP_PATH"
    echo "✓ Claude Hub 已启动"
  else
    echo "⚠ 未找到 $APP_PATH，请先执行: bash $HUB_DIR/scripts/build-swift-app.sh"
  fi
else
  echo "✓ Claude Hub 已在运行"
fi

# 2. 启动 Claude 调度中心
cd "$HUB_DIR"
exec claude
