#!/bin/bash
# Claude 调度中心 - 启动欢迎界面
# 读取 projects.yaml 显示项目列表 + 每个项目的 git 状态

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
YAML_FILE="$PROJECT_DIR/projects.yaml"

# 颜色
CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

# 输出某个目录的 git 状态行（缩进 7 空格 + └─）
git_status_line() {
  local dir="$1"
  if [ ! -d "$dir" ]; then
    echo -e "       ${DIM}└─ ${RED}目录不存在${NC}"
    return
  fi
  if [ ! -d "$dir/.git" ] && ! git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
    echo -e "       ${DIM}└─ 非 git 仓库${NC}"
    return
  fi

  local branch
  branch=$(git -C "$dir" branch --show-current 2>/dev/null)
  [ -z "$branch" ] && branch="(detached)"

  local changes
  changes=$(git -C "$dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')

  local upstream ahead=0 behind=0
  upstream=$(git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)
  if [ -n "$upstream" ]; then
    local counts
    counts=$(git -C "$dir" rev-list --left-right --count "HEAD...$upstream" 2>/dev/null)
    ahead=$(echo "$counts" | awk '{print $1}')
    behind=$(echo "$counts" | awk '{print $2}')
  fi

  # 干净 / 脏
  local sym status_color status_text
  if [ "$changes" = "0" ]; then
    sym="✓"; status_color="${GREEN}"; status_text="干净"
  else
    sym="●"; status_color="${YELLOW}"; status_text="${changes} 个未提交"
  fi

  # 远端追踪信息
  local extra=""
  if [ -z "$upstream" ]; then
    extra=" ${DIM}· 无 upstream${NC}"
  else
    [ "$ahead"  != "0" ] && extra="${extra} ${DIM}·${NC} ${YELLOW}↑${ahead} 未推送${NC}"
    [ "$behind" != "0" ] && extra="${extra} ${DIM}·${NC} ${RED}↓${behind} 落后${NC}"
  fi

  echo -e "       ${DIM}└─${NC} ${status_color}${sym}${NC} ${BOLD}${branch}${NC} ${DIM}·${NC} ${status_color}${status_text}${NC}${extra}"
}

# 顶部
echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "  ${BOLD}Claude 调度中心${NC}  ${DIM}v1.1${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"

if [ ! -f "$YAML_FILE" ]; then
  echo -e "  ${YELLOW}projects.yaml 未找到${NC}"
  exit 0
fi

echo ""
echo -e "  ${BOLD}项目列表：${NC}"
echo ""

# 解析 YAML：每读到下一个 - name: 时，把上一个项目 flush 出来
INDEX=0
CUR_NAME=""
CUR_PATH=""
CUR_DESC=""

flush_project() {
  if [ -n "$CUR_NAME" ]; then
    INDEX=$((INDEX + 1))
    printf "   ${GREEN}%2d.${NC} ${BOLD}%-18s${NC} ${DIM}%s${NC}\n" "$INDEX" "$CUR_NAME" "$CUR_DESC"
    local expanded="${CUR_PATH/#\~/$HOME}"
    git_status_line "$expanded"
  fi
  CUR_NAME=""; CUR_PATH=""; CUR_DESC=""
}

while IFS= read -r line; do
  if echo "$line" | grep -q "^  - name:"; then
    flush_project
    CUR_NAME=$(echo "$line" | sed 's/.*name: *//')
  elif echo "$line" | grep -q "^    path:"; then
    CUR_PATH=$(echo "$line" | sed 's/.*path: *//')
  elif echo "$line" | grep -q "^    description:"; then
    CUR_DESC=$(echo "$line" | sed 's/.*description: *"//;s/"$//')
  fi
done < "$YAML_FILE"
flush_project  # 最后一个

echo ""

# tmux 状态
if tmux has-session -t hub 2>/dev/null; then
  WINDOWS=$(tmux list-windows -t hub -F '#{window_name}' | tr '\n' ', ' | sed 's/,$//')
  echo -e "  ${GREEN}tmux hub: 运行中${NC} ${DIM}[${WINDOWS}]${NC}"
else
  echo -e "  ${DIM}tmux hub: 未启动${NC}"
fi

echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "  ${DIM}说 \"开发 {项目名}\" 打开项目  |  \"状态\" 查看所有窗口${NC}"
echo -e "  ${DIM}图例：${NC}${GREEN}✓${NC} ${DIM}干净${NC}  ${YELLOW}●${NC} ${DIM}未提交${NC}  ${YELLOW}↑${NC} ${DIM}未推送${NC}  ${RED}↓${NC} ${DIM}落后远端${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo ""
