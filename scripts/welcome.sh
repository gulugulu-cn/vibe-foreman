#!/bin/bash
# Claude 调度中心 - 启动欢迎界面
# 读取 projects.yaml 显示项目列表

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
YAML_FILE="$PROJECT_DIR/projects.yaml"

# 颜色定义
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

# 顶部边框
echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC}${BOLD}          Claude 调度中心  ${NC}${DIM}v1.0${NC}${CYAN}                       ║${NC}"
echo -e "${CYAN}╠══════════════════════════════════════════════════════╣${NC}"

# 读取项目列表
if [ ! -f "$YAML_FILE" ]; then
  echo -e "${CYAN}║${NC}  ${YELLOW}projects.yaml 未找到${NC}                                ${CYAN}║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
  exit 0
fi

# 解析 YAML（简单方式，不依赖 yq）
echo -e "${CYAN}║${NC}  ${BOLD}项目列表：${NC}                                          ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}                                                      ${CYAN}║${NC}"

INDEX=0
while IFS= read -r line; do
  if echo "$line" | grep -q "^  - name:"; then
    NAME=$(echo "$line" | sed 's/.*name: *//')
    INDEX=$((INDEX + 1))
  fi
  if echo "$line" | grep -q "^    description:"; then
    DESC=$(echo "$line" | sed 's/.*description: *"//;s/"$//')
    # 格式化输出
    printf "${CYAN}║${NC}  ${GREEN}%2d.${NC} ${BOLD}%-16s${NC} ${DIM}%s${NC}" "$INDEX" "$NAME" "$DESC"
    # 补齐空格到固定宽度
    CONTENT_LEN=$((4 + 16 + ${#DESC}))
    PADDING=$((50 - CONTENT_LEN))
    if [ $PADDING -gt 0 ]; then
      printf "%${PADDING}s" ""
    fi
    printf "${CYAN}║${NC}\n"
  fi
done < "$YAML_FILE"

echo -e "${CYAN}║${NC}                                                      ${CYAN}║${NC}"

# tmux 状态
if tmux has-session -t hub 2>/dev/null; then
  WINDOWS=$(tmux list-windows -t hub -F '#{window_name}' | tr '\n' ', ' | sed 's/,$//')
  echo -e "${CYAN}║${NC}  ${GREEN}tmux hub: 运行中${NC} [${WINDOWS}]"
  printf "%$((52 - 18 - ${#WINDOWS}))s${CYAN}║${NC}\n" ""
else
  echo -e "${CYAN}║${NC}  ${DIM}tmux hub: 未启动${NC}                                   ${CYAN}║${NC}"
fi

echo -e "${CYAN}╠══════════════════════════════════════════════════════╣${NC}"
echo -e "${CYAN}║${NC}  ${DIM}说\"开发 {项目名}\" 打开项目  |  \"状态\" 查看所有窗口${NC}  ${CYAN}║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
