#!/usr/bin/env bash
# clone-project.sh —— 克隆远程仓库并注册进 hub
#
# 用法：
#   clone-project.sh <owner/repo|git地址> [--dir <parent>] [--name <本地目录名>]
#
# 有 gh 用 gh repo clone（吃 gh 的登录态，私有仓不用配 token），
# 没有就退化 git clone。克隆完自动注册进 projects.yaml。
set -euo pipefail

HUB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CYAN=$'\033[36m'; GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'
say()  { echo "${CYAN}▸${RESET} $*"; }
ok()   { echo "${GREEN}✓${RESET} $*"; }
die()  { echo "${RED}✗${RESET} $*" >&2; exit 1; }

REPO="${1:-}"
[ -n "$REPO" ] || die "用法：clone-project.sh <owner/repo|git地址> [--dir <parent>] [--name <目录名>]"
shift

PARENT="$HOME/Documents/code"
NAME=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dir)  PARENT="${2:?--dir 需要参数}"; shift 2 ;;
    --name) NAME="${2:?--name 需要参数}"; shift 2 ;;
    *) die "未知选项：$1" ;;
  esac
done

PARENT="${PARENT/#\~/$HOME}"
if [ -z "$NAME" ]; then
  NAME="${REPO##*/}"
  NAME="${NAME%.git}"
fi
TARGET="$PARENT/$NAME"
[ -e "$TARGET" ] && die "目标已存在：$TARGET"
mkdir -p "$PARENT"

say "克隆 $REPO -> $TARGET"
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  gh repo clone "$REPO" "$TARGET" || die "gh repo clone 失败"
else
  git clone "$REPO" "$TARGET" || die "git clone 失败"
fi
ok "克隆完成"

if [ -x "$HUB_DIR/scripts/add-project.sh" ]; then
  bash "$HUB_DIR/scripts/add-project.sh" "$NAME" "$TARGET" >/dev/null 2>&1 \
    && ok "已注册进 projects.yaml" \
    || echo "（注册 projects.yaml 失败，可手动：bash ${HUB_DIR}/scripts/add-project.sh ${NAME} ${TARGET}）"
fi

echo
ok "完成：$TARGET"
