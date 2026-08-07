#!/usr/bin/env bash
# 盯住某个 tmux 窗口里的 Claude，停下来就追问，直到它把活干透。
#
# 用法：bash keep-going.sh <tmux窗口> [追问清单文件|单条催促语]
#   例：bash keep-going.sh hub:1 probes/agentx-training.txt
#       bash keep-going.sh hub:1 "继续，不要停"
#
# ── 为什么是「追问清单」而不是一句「继续」 ──────────────────────
#
# 「继续」只能防它**停**，防不了它**做浅**。它完全可以每次都继续、
# 每次都做表面功夫，最后给一份看起来很完整的报告。
#
# 观察者的价值在于问它不想被问的那些：测了几轮、调过什么参数、
# 哪些卡点没解决、有没有落盘。所以清单里的每一条都是一个角度，
# 轮着问，到底了从头再来。
#
# ── 怎么判断"停了" ────────────────────────────────────────────────
#
# **不靠截屏猜。** 屏幕上有没有转圈、输入框空不空，都会因为终端宽度、
# 主题、正在滚动而变，猜错的代价是往一个正在干活的会话里插一句话。
#
# 靠 Claude Code 自己写的状态文件 `~/.claude/sessions/<pid>.json`，
# 里面的 status 是权威的（Hub 的会话列表也读它）。
#
# pid 从 tmux pane 反查，不是写死的 —— 会话中途重启（resume）会换 pid，
# 写死的话盯梢就断了而且毫无征兆。
set -uo pipefail

TARGET="${1:?用法：keep-going.sh <tmux窗口> [追问清单文件|催促语]}"
SOURCE="${2:-继续，不要停。遇到问题自己想办法解决，把活干完再停。}"

# 追问清单：一条一行，# 开头和空行忽略。给的不是文件就当成单条催促语。
PROBES=()
if [ -f "$SOURCE" ]; then
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue;; esac
    PROBES+=("$line")
  done < "$SOURCE"
fi
[ ${#PROBES[@]} -eq 0 ] && PROBES=("$SOURCE")
probe_index=0

INTERVAL=45          # 多久看一眼
NEED_STREAK=2        # 连续几次非工作态才认定"真停了"（≈90 秒）
COOLDOWN=180         # 催完之后至少隔这么久才再催
LOG=/tmp/keep-going-$(echo "$TARGET" | tr ':' '-').log

streak=0
last_nudge=0

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

log "开始盯 $TARGET —— 每 ${INTERVAL}s 看一次，连续 ${NEED_STREAK} 次不在干活才追问；清单共 ${#PROBES[@]} 条"

while true; do
  if ! tmux list-panes -t "$TARGET" >/dev/null 2>&1; then
    log "窗口没了，退出"
    exit 0
  fi

  pane_pid=$(tmux list-panes -t "$TARGET" -F '#{pane_pid}' 2>/dev/null | head -1)
  state=$(python3 - "$pane_pid" <<'PY' 2>/dev/null || echo unknown
import json, os, sys
pid = sys.argv[1]
path = os.path.expanduser(f"~/.claude/sessions/{pid}.json")
try:
    with open(path) as handle:
        print(json.load(handle).get("status") or "unknown")
except Exception:
    print("unknown")
PY
)

  now=$(date +%s)
  case "$state" in
    busy|shell)
      # 在干活。streak 清零 —— 中途喘口气不算停。
      [ "$streak" -gt 0 ] && log "又开始干活了（$state），计数清零"
      streak=0
      ;;
    idle|waiting)
      streak=$((streak + 1))
      if [ "$streak" -ge "$NEED_STREAK" ] && [ $((now - last_nudge)) -ge "$COOLDOWN" ]; then
        message="${PROBES[$probe_index]}"
        probe_index=$(( (probe_index + 1) % ${#PROBES[@]} ))

        # 分两次发：先文字，停一下再回车。
        # 合在一起发时，终端偶尔会把回车吃进上一段输入里，消息就卡在输入框不发出去 ——
        # 看起来催过了，其实一个字都没送出去。
        tmux send-keys -t "$TARGET" "$message"
        sleep 1
        tmux send-keys -t "$TARGET" Enter
        log "状态 $state → 追问第 $((probe_index == 0 ? ${#PROBES[@]} : probe_index))/${#PROBES[@]} 条：${message:0:40}…"
        last_nudge=$now
        streak=0
      else
        log "状态 $state（第 $streak 次）"
      fi
      ;;
    unknown)
      # 状态文件读不到：可能刚重启、也可能 claude 已经退了。
      # **这种情况不催** —— 往一个不确定的窗口里敲字比不敲危险。
      log "状态读不出来（pane pid=$pane_pid），先不动"
      streak=0
      ;;
  esac

  sleep "$INTERVAL"
done
