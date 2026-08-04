#!/bin/bash
# 添加项目到 projects.yaml
# 用法: bash scripts/add-project.sh <name> <path> [aliases...]
#
# 示例:
#   bash scripts/add-project.sh acme-erp ~/code/acme-admin acme-admin erp 后台

HUB_DIR="$(cd "$(dirname "$0")/.." && pwd)"
YAML_FILE="$HUB_DIR/projects.yaml"

NAME="$1"
PROJECT_PATH="$2"
shift 2
ALIASES=("$@")

if [ -z "$NAME" ] || [ -z "$PROJECT_PATH" ]; then
  echo "用法: add-project.sh <name> <path> [aliases...]"
  echo "示例: add-project.sh acme-erp ~/code/acme-admin acme-admin erp"
  exit 1
fi

# 展开 ~ 检查路径
EXPANDED_PATH="${PROJECT_PATH/#\~/$HOME}"
if [ ! -d "$EXPANDED_PATH" ]; then
  echo "警告: 目录不存在 $PROJECT_PATH（会继续添加）"
fi

# 确保 projects.yaml 存在
if [ ! -f "$YAML_FILE" ]; then
  cp "$HUB_DIR/projects.yaml.example" "$YAML_FILE" 2>/dev/null || cat > "$YAML_FILE" << 'EOF'
# 项目清单

projects:
EOF
fi

# 检查是否已存在
if grep -q "name: $NAME" "$YAML_FILE" 2>/dev/null; then
  echo "项目 $NAME 已存在于 projects.yaml"
  exit 1
fi

# 构建别名字符串
ALIAS_STR=""
if [ ${#ALIASES[@]} -gt 0 ]; then
  ALIAS_STR="    aliases: [$(IFS=', '; echo "${ALIASES[*]}")]"
fi

# 追加
cat >> "$YAML_FILE" << EOF

  - name: $NAME
${ALIAS_STR:+$ALIAS_STR
}    path: $PROJECT_PATH
    description: ""
    tags: []
EOF

echo "已添加: $NAME → $PROJECT_PATH"
if [ ${#ALIASES[@]} -gt 0 ]; then
  echo "  别名: ${ALIASES[*]}"
fi

# 必须显式 exit 0。
# 之前最后一行是 `[ ${#ALIASES[@]} -gt 0 ] && echo ...`：没有别名时这个测试为假，
# 脚本退出码就成了 1 —— 明明写进去了，调用方（clone-project.sh / app）却报
# "注册 projects.yaml 失败"。真踩过。
exit 0
