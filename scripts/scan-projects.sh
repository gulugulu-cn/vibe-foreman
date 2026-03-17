#!/bin/bash
# 扫描目录下的 git 仓库，自动生成 projects.yaml
# 用法: bash scripts/scan-projects.sh [目录] [--append]
#
# 不传目录默认扫描 ~/Documents/code
# --append 追加到已有 projects.yaml，不覆盖

SCAN_DIR="${1:-$HOME/Documents/code}"
APPEND=false
HUB_DIR="$(cd "$(dirname "$0")/.." && pwd)"
YAML_FILE="$HUB_DIR/projects.yaml"

# 检查 --append 参数
for arg in "$@"; do
  [ "$arg" = "--append" ] && APPEND=true
done

# 展开 ~
SCAN_DIR="${SCAN_DIR/#\~/$HOME}"

if [ ! -d "$SCAN_DIR" ]; then
  echo "目录不存在: $SCAN_DIR"
  exit 1
fi

echo "扫描 $SCAN_DIR 下的 git 仓库..."

# 收集项目
PROJECTS=""
COUNT=0

for dir in "$SCAN_DIR"/*/; do
  [ ! -d "$dir/.git" ] && continue

  NAME=$(basename "$dir")
  PATH_STR="${dir%/}"
  # 用 ~ 缩短路径
  PATH_STR="${PATH_STR/#$HOME/~}"

  PROJECTS+="  - name: $NAME
    path: $PATH_STR
    description: \"\"
    tags: []

"
  COUNT=$((COUNT + 1))
  echo "  发现: $NAME ($PATH_STR)"
done

if [ $COUNT -eq 0 ]; then
  echo "未发现 git 仓库"
  exit 0
fi

echo ""
echo "发现 $COUNT 个项目"

if [ "$APPEND" = true ] && [ -f "$YAML_FILE" ]; then
  echo "" >> "$YAML_FILE"
  echo "  # === 扫描添加 $(date '+%Y-%m-%d') ===" >> "$YAML_FILE"
  echo "$PROJECTS" >> "$YAML_FILE"
  echo "已追加到 $YAML_FILE"
else
  cat > "$YAML_FILE" << EOF
# 项目清单 - 由 scan-projects.sh 自动生成
# 生成时间: $(date '+%Y-%m-%d %H:%M')
# 扫描目录: $SCAN_DIR
#
# 你可以手动编辑此文件添加 aliases 和 description

projects:
$PROJECTS
EOF
  echo "已写入 $YAML_FILE"
fi
