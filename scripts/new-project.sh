#!/usr/bin/env bash
# new-project.sh —— 一键创建新项目：目录 + git + GitHub 远程 + 防污染配置 + 注册进 hub
#
# 用法：
#   new-project.sh <name> [选项]
#
# 选项：
#   --dir <parent>     父目录（默认 ~/Documents/code）
#   --private          GitHub 建私有仓（默认）
#   --public           GitHub 建公开仓
#   --no-remote        只建本地仓，不创建 GitHub 远程
#   --no-deny          不写防污染 deny 配置
#   --desc "<text>"    项目描述（进 README 和 projects.yaml）
#
# 防污染 deny 说明：
#   禁止 Write/Edit 宿主机 ~/.claude/ 的 agents/skills/commands/memory/CLAUDE.md，
#   把「项目会话把知识写进全局面」的污染路径堵死。
#   **刻意不禁 ~/.claude/plans/**：plan mode 的计划文件就写在那里，
#   禁了它所有 plan 会话都会报 "Error writing file"（在 agentx-dev-kit 真踩过）。
#   deny 与 autoMemoryDirectory 必须成对存在——只禁不给去处等于把记忆扔了。
set -euo pipefail

HUB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CYAN=$'\033[36m'; GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'
say()  { echo "${CYAN}▸${RESET} $*"; }
ok()   { echo "${GREEN}✓${RESET} $*"; }
die()  { echo "${RED}✗${RESET} $*" >&2; exit 1; }

NAME="${1:-}"
[ -n "$NAME" ] || die "用法：new-project.sh <name> [--dir <parent>] [--public|--private] [--no-remote] [--no-deny] [--desc <text>]"
shift

PARENT="$HOME/Documents/code"
VISIBILITY="--private"
REMOTE=1
DENY=1
DESC=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)       PARENT="${2:?--dir 需要参数}"; shift 2 ;;
    --public)    VISIBILITY="--public"; shift ;;
    --private)   VISIBILITY="--private"; shift ;;
    --no-remote) REMOTE=0; shift ;;
    --no-deny)   DENY=0; shift ;;
    --desc)      DESC="${2:?--desc 需要参数}"; shift 2 ;;
    *) die "未知选项：$1" ;;
  esac
done

PARENT="${PARENT/#\~/$HOME}"
TARGET="$PARENT/$NAME"
[ -e "$TARGET" ] && die "目标已存在：$TARGET"
command -v git >/dev/null || die "找不到 git"
if [ "$REMOTE" = 1 ]; then
  command -v gh >/dev/null || die "找不到 gh（GitHub CLI）；用 --no-remote 可只建本地仓"
  gh auth status >/dev/null 2>&1 || die "gh 未登录：先跑 gh auth login"
fi

say "创建 $TARGET"
mkdir -p "$TARGET"
cd "$TARGET"
git init -q -b main

# README
{
  echo "# $NAME"
  [ -n "$DESC" ] && { echo; echo "$DESC"; }
} > README.md

# 基础 .gitignore
cat > .gitignore <<'EOF'
.DS_Store
node_modules/
.env
.env.*
*.log
EOF

# 防污染配置 + 项目内记忆目录
if [ "$DENY" = 1 ]; then
  mkdir -p .claude/memory
  touch .claude/memory/.gitkeep
  cat > .claude/settings.json <<'EOF'
{
  "_doc": "项目级防污染配置：项目知识只落项目内（见 autoMemoryDirectory），禁止写进宿主机 ~/.claude/（那是全局面，写进去会污染其他项目的会话）。只写 Edit 规则、不写 Write 规则：Edit(path) 已经覆盖所有文件编辑工具（含 Write），而单独的 Write(path) 规则不被权限检查识别，加了只会每次调用都刷警告。注意：~/.claude/plans/ 不能列入 deny——plan mode 的计划文件就写在那里，禁了它所有 plan 会话都会报 Error writing file（真踩过）。deny 与 autoMemoryDirectory 必须成对存在——只禁不给去处等于把记忆扔了。",
  "autoMemoryDirectory": "./.claude/memory",
  "permissions": {
    "deny": [
      "Edit(~/.claude/agents/**)",
      "Edit(~/.claude/skills/**)",
      "Edit(~/.claude/commands/**)",
      "Edit(~/.claude/projects/*/memory/**)",
      "Edit(~/.claude/CLAUDE.md)"
    ]
  }
}
EOF
  ok "已写入 .claude/settings.json（防污染 deny + 项目内记忆目录）"
fi

git add -A
git commit -qm "init: $NAME"
ok "本地仓已建好（分支 main）"

# GitHub 远程
if [ "$REMOTE" = 1 ]; then
  # 注意：macOS 自带 bash 3.2 会把紧跟在变量后的全角字符吞进变量名，
  # 变量与中文标点相邻时必须用 ${} 括起来。
  say "创建 GitHub 远程仓（${VISIBILITY}）"
  if gh repo create "$NAME" "$VISIBILITY" --source . --remote origin --push; then
    ok "已推送：$(git remote get-url origin)"
  else
    echo "${RED}✗${RESET} GitHub 建仓失败（同名仓已存在？），本地仓保留在 $TARGET" >&2
    echo "  手动补救：gh repo create $NAME $VISIBILITY --source \"$TARGET\" --remote origin --push" >&2
  fi
fi

# 注册进 hub 的 projects.yaml
if [ -x "$HUB_DIR/scripts/add-project.sh" ]; then
  bash "$HUB_DIR/scripts/add-project.sh" "$NAME" "$TARGET" >/dev/null 2>&1 \
    && ok "已注册进 projects.yaml" \
    || echo "（注册 projects.yaml 失败，可手动：bash ${HUB_DIR}/scripts/add-project.sh ${NAME} ${TARGET}）"
fi

echo
ok "完成：$TARGET"
[ "$REMOTE" = 1 ] && git remote get-url origin 2>/dev/null | sed 's/^/  remote: /'
