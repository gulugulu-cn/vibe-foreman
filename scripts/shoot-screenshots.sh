#!/bin/bash
# 用演示数据重截全部岛截图。
#
# ## 为什么必须是演示数据
#
# 真实工作区的截图里全是内部项目名、分支名和需求原文。README 里那批图
# 是要发出去的 —— 一张真图混进去，泄露的不是"用了什么工具"，
# 是"在做什么产品"。DemoFixtures 造的是 storefront / api-gateway /
# billing-service 这种任何团队都可能有的名字。
#
# ## 为什么能自动截
#
# 岛的形态用 HUB_ISLAND_STATE 钉死（`projects` 顺带切到项目栏），
# 不需要控制鼠标。这个变量本来就是为截图留的。
#
# 用法：bash scripts/shoot-screenshots.sh [形态...]
#   不传 = 全截。

set -euo pipefail

HUB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="/Applications/Vibe Foreman Free.app/Contents/MacOS/ClaudeHub"
OUT="$HUB_DIR/docs/screenshots"
FINDER="$HUB_DIR/scripts/find-window.swift"

log() { printf '\033[36m▸\033[0m %s\n' "$1"; }
ok() { printf '\033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '\033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }

[ -x "$APP" ] || fail "先装 app：bash scripts/build-swift-app.sh"

# 形态 → 输出文件名
shoot() {
  local state="$1" name="$2"

  pkill -x ClaudeHub 2>/dev/null || true
  sleep 1

  HUB_DEMO=1 HUB_ISLAND_STATE="$state" "$APP" >/dev/null 2>&1 &
  local pid=$!

  # **轮询而不是固定 sleep。** 冷启动、Liquid Glass 首帧、以及不同形态的
  # 布局耗时都不一样，写死一个秒数必然在某台机器或某个形态上翻车 ——
  # 实测 4 秒对 hover 够、对 expanded 不够。
  local win="" tries=0
  while [ $tries -lt 30 ]; do
    win=$(swift "$FINDER" 2>/dev/null | head -1 | awk '{print $1}')
    [ -n "$win" ] && break
    sleep 0.5
    tries=$((tries + 1))
  done
  if [ -z "$win" ]; then
    kill "$pid" 2>/dev/null || true
    fail "找不到岛的窗口（${state}）"
  fi
  # 窗口出现了不等于画完了。再等一下让首帧渲染稳定，
  # 否则会截到玻璃材质还没铺开的中间态。
  sleep 1.5

  # -o 去掉窗口阴影：阴影会在深色底的长图上糊成一片。
  screencapture -x -o -l"$win" "$OUT/$name" 2>/dev/null \
    || fail "截图失败（${state}）"

  # 岛画在一个 640×720 的透明容器窗口里（形态变化时不用改窗口尺寸），
  # 截下来四周有大片透明。不裁的话拼进长图就是一块巨大的空白。
  swift "$HUB_DIR/scripts/crop-alpha.swift" "$OUT/$name" >/dev/null

  kill "$pid" 2>/dev/null || true
  ok "$name  ←  $state"
}

# 主窗口。和岛不一样：它不是靠 HUB_ISLAND_STATE 钉形态，而是
# HUB_OPEN_WINDOW=1 打开 + HUB_WINDOW_SECTION 钉住打开哪一页。
#
# 也不裁 alpha —— 主窗口是实心的，crop-alpha 会把圆角外那圈透明像素
# 连着窗口边一起削掉。
shoot_window() {
  local section="$1" name="$2"

  pkill -x ClaudeHub 2>/dev/null || true
  sleep 1

  HUB_DEMO=1 HUB_OPEN_WINDOW=1 HUB_WINDOW_SECTION="$section" "$APP" >/dev/null 2>&1 &
  local pid=$!

  # **按宽度挑，不能取第一个。** find-window 按面积排序，而岛的容器窗口
  # （640×720）比主窗口（940×640）先出现一瞬 —— 取第一个就会截到岛，
  # 而且那一张看起来像是"截图脚本坏了"，不像"截错窗口了"。
  # 主窗口最小宽度是 780，用 900 卡住足够把两者分开。
  local win="" tries=0
  while [ $tries -lt 40 ]; do
    win=$(swift "$FINDER" 2>/dev/null | awk '$2 >= 900 {print $1; exit}')
    [ -n "$win" ] && break
    sleep 0.5
    tries=$((tries + 1))
  done
  if [ -z "$win" ]; then
    kill "$pid" 2>/dev/null || true
    fail "找不到主窗口（${section}）"
  fi
  sleep 1.5

  screencapture -x -o -l"$win" "$OUT/$name" 2>/dev/null || fail "截图失败（${section}）"
  kill "$pid" 2>/dev/null || true
  ok "$name  ←  主窗口/$section"
}

if [ $# -gt 0 ]; then
  for s in "$@"; do
    case "$s" in
      hover) shoot hover 01-hover.png ;;
      expanded) shoot expanded 02-expanded-sessions.png ;;
      projects) shoot projects 03-expanded-projects.png ;;
      nudge) shoot nudge 05-nudge.png ;;
      answer) shoot answer 06-answer.png ;;
      secrets) shoot_window secrets 10-secrets.png ;;
      credentials) shoot_window credentials 11-credentials.png ;;
      window) shoot_window sessions 04-main-window.png ;;
      *) fail "不认识的形态：$s" ;;
    esac
  done
else
  shoot hover 01-hover.png
  shoot expanded 02-expanded-sessions.png
  shoot projects 03-expanded-projects.png
  shoot nudge 05-nudge.png
  shoot answer 06-answer.png
  shoot_window secrets 10-secrets.png
  shoot_window credentials 11-credentials.png
fi

pkill -x ClaudeHub 2>/dev/null || true
echo
log "重新生成长图"
swift "$HUB_DIR/Resources/make-poster.swift"
echo
ok "完成。记得把正常版本的 app 重新起来：open -a 'Vibe Foreman Free'"
