#!/bin/bash
# 项目入口菜单 - tmux 窗口打开时自动显示
# 用法: project-menu.sh <项目名> <项目路径>

NAME="$1"
DIR="$2"

# 颜色
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

cd "$DIR" 2>/dev/null || exit 1

# 注入 hub 环境
export PATH="$HOME/Documents/code/claude-hub/scripts:$PATH"
alias hub-notify="bash $HOME/Documents/code/claude-hub/scripts/hub-notify.sh"
alias hub-run="bash $HOME/Documents/code/claude-hub/scripts/hub-run.sh"

# 显示项目信息
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  $NAME${NC}"
echo -e "${DIM}  $DIR${NC}"

# git 信息
if [ -d .git ]; then
  BRANCH=$(git branch --show-current 2>/dev/null)
  STATUS=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  echo -e "${DIM}  git: ${GREEN}$BRANCH${NC} ${DIM}($STATUS 个变更)${NC}"
fi

echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${GREEN}1${NC}) Claude Code"
echo -e "  ${GREEN}2${NC}) Claude Code ${YELLOW}(--dangerously-skip-permissions)${NC}"
echo -e "  ${GREEN}3${NC}) 直接终端"
echo -e "  ${GREEN}4${NC}) 打开 Finder"
echo -e "  ${GREEN}5${NC}) 打开 VS Code"
echo ""
echo -ne "${YELLOW}选择 [1-5, 默认 3, 30秒超时]: ${NC}"

read -t 30 choice

case "${choice:-3}" in
  1)
    echo -e "${DIM}启动 Claude Code...${NC}"
    claude
    ;;
  2)
    echo -e "${DIM}启动 Claude Code (skip permissions)...${NC}"
    claude --dangerously-skip-permissions
    ;;
  3)
    echo -e "${DIM}进入终端${NC}"
    exec $SHELL
    ;;
  4)
    open "$DIR"
    echo -e "${DIM}Finder 已打开${NC}"
    exec $SHELL
    ;;
  5)
    code "$DIR"
    echo -e "${DIM}VS Code 已打开${NC}"
    exec $SHELL
    ;;
  *)
    exec $SHELL
    ;;
esac
