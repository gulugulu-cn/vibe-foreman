#!/bin/bash
# 扫描目录下的 git 仓库，生成/更新 projects.yaml
# 用法: bash scripts/scan-projects.sh [目录...]
#
# 不传目录 → 从 projects.yaml 的 scan_dirs 读取
# 传目录 → 扫描指定目录

HUB_DIR="$(cd "$(dirname "$0")/.." && pwd)"
YAML_FILE="$HUB_DIR/projects.yaml"

# 收集扫描目录
SCAN_DIRS=()

if [ $# -gt 0 ]; then
  # 命令行传入的目录
  for arg in "$@"; do
    SCAN_DIRS+=("${arg/#\~/$HOME}")
  done
elif [ -f "$YAML_FILE" ]; then
  # 从 projects.yaml 的 scan_dirs 读取
  while IFS= read -r line; do
    dir=$(echo "$line" | sed 's/^[[:space:]]*-[[:space:]]*//' | sed "s|~|$HOME|g")
    [ -d "$dir" ] && SCAN_DIRS+=("$dir")
  done < <(grep -A 100 '^scan_dirs:' "$YAML_FILE" | tail -n +2 | grep '^  -' | sed '/^[a-z]/q' | head -20)
fi

# 默认目录
if [ ${#SCAN_DIRS[@]} -eq 0 ]; then
  SCAN_DIRS=("$HOME/Documents/code")
fi

echo "扫描目录:"
for d in "${SCAN_DIRS[@]}"; do echo "  $d"; done
echo ""

# 收集已有项目（避免重复）
EXISTING=""
if [ -f "$YAML_FILE" ]; then
  EXISTING=$(grep 'name:' "$YAML_FILE" | sed 's/.*name:[[:space:]]*//')
fi

# 扫描所有目录
PROJECTS=""
COUNT=0
SKIP=0

for SCAN_DIR in "${SCAN_DIRS[@]}"; do
  [ ! -d "$SCAN_DIR" ] && continue

  for dir in "$SCAN_DIR"/*/; do
    [ ! -d "$dir/.git" ] && continue

    NAME=$(basename "$dir")

    # 跳过已存在的
    if echo "$EXISTING" | grep -q "^${NAME}$"; then
      SKIP=$((SKIP + 1))
      continue
    fi

    PATH_STR="${dir%/}"
    PATH_STR="${PATH_STR/#$HOME/~}"

    PROJECTS+="  - name: $NAME
    path: $PATH_STR
    description: \"\"
    tags: []

"
    COUNT=$((COUNT + 1))
    echo "  新增: $NAME ($PATH_STR)"
  done
done

[ $SKIP -gt 0 ] && echo "  跳过: $SKIP 个已存在的项目"
echo ""

if [ $COUNT -eq 0 ]; then
  echo "没有新项目需要添加"
  exit 0
fi

echo "发现 $COUNT 个新项目"

# 确保 projects.yaml 存在
if [ ! -f "$YAML_FILE" ]; then
  # 读取 scan_dirs 参数生成 scan_dirs 配置
  SCAN_DIRS_YAML=""
  for d in "${SCAN_DIRS[@]}"; do
    d="${d/#$HOME/~}"
    SCAN_DIRS_YAML+="  - $d\n"
  done

  cat > "$YAML_FILE" << EOF
# 项目清单 - 由 scan-projects.sh 生成

scan_dirs:
$(echo -e "$SCAN_DIRS_YAML")
projects:
$PROJECTS
EOF
  echo "已创建 $YAML_FILE"
else
  # 追加到已有文件
  echo "" >> "$YAML_FILE"
  echo "  # === 扫描添加 $(date '+%Y-%m-%d') ===" >> "$YAML_FILE"
  echo -n "$PROJECTS" >> "$YAML_FILE"
  echo "已追加到 $YAML_FILE"
fi
