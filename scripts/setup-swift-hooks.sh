#!/bin/bash
# 把 Claude Hub 的 hook 装进 ~/.claude/settings.json。
#
# 替换掉旧的 bash hook（hub-hook-stop.sh / hub-hook-permission.sh）。旧实现的问题：
#   1. 用 `tmux display-message -p '#W'` 且**没带 -t "$TMUX_PANE"**，
#      拿到的是当前 active 窗口名而不是自己所在的窗口 —— 用户切个 tab
#      通知就挂到别的项目上了；
#   2. 完全没读 stdin，session_id / cwd / last_assistant_message 全丢；
#   3. terminal-notifier 的 -activate 只能前置 iTerm，选不了具体 tab，
#      这正是「点了通知没跳到对应窗口」的直接原因；
#   4. 配的是 "async": false 且 hook 里同步 afplay，
#      **每轮回复结束都被语音播放阻塞几百毫秒**。
#
# 新实现用 hubctl（Swift 二进制）：读 stdin、走 Unix socket、
# Hub 没运行时立刻放行（fail-open）。

set -euo pipefail

# 这个脚本有两种跑法，路径解析必须都成立：
#   1. 从仓库里跑：`bash scripts/setup-swift-hooks.sh`
#   2. 从 dmg 里双击「安装 hook.command」—— 这时上一级是 /Volumes，
#      仓库根本不存在。所以 HUB_DIR 只是**可选**的额外查找位置，
#      真正的主来源是已安装的 /Applications/Claude Hub.app。
HUB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ ! -d "$HUB_DIR/HubKit" ]; then HUB_DIR=""; fi

SETTINGS="$HOME/.claude/settings.json"
BIN_DIR="$HOME/.local/bin"
HUBCTL="$BIN_DIR/hubctl"

log() { printf '\033[36m▸\033[0m %s\n' "$1"; }
ok() { printf '\033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '\033[33m!\033[0m %s\n' "$1"; }
fail() { printf '\033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }

# ---------- 定位 hubctl ----------

SOURCE=""
for candidate in \
  "/Applications/Claude Hub.app/Contents/Helpers/hubctl" \
  "$HUB_DIR/HubKit/.build/release/hubctl" \
  "$HUB_DIR/HubKit/.build/debug/hubctl"; do
  if [ -x "$candidate" ]; then SOURCE="$candidate"; break; fi
done

if [ -z "$SOURCE" ]; then
  fail "找不到 hubctl。先把 Claude Hub.app 拖进「应用程序」，或运行 bash scripts/build-swift-app.sh"
fi

mkdir -p "$BIN_DIR"
cp "$SOURCE" "$HUBCTL"
chmod +x "$HUBCTL"
ok "已安装 hubctl → $HUBCTL"

# ---------- 写 settings.json ----------

[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
log "已备份 $SETTINGS"

HUBCTL="$HUBCTL" python3 - "$SETTINGS" <<'PYTHON'
import json, os, sys

path = sys.argv[1]
hubctl = os.environ["HUBCTL"]

with open(path) as handle:
    settings = json.load(handle)

hooks = settings.setdefault("hooks", {})

def strip_legacy(entries):
    """移除旧的 bash hook，保留用户自己配的其它 hook。"""
    kept = []
    for entry in entries or []:
        commands = [h.get("command", "") for h in entry.get("hooks", [])]
        if any("hub-hook-" in c or "hubctl hook" in c for c in commands):
            continue
        kept.append(entry)
    return kept

def install(event, argument, *, blocking, timeout=90):
    entries = strip_legacy(hooks.get(event))
    hook = {"type": "command", "command": f"{hubctl} hook {argument}"}
    if blocking:
        # PreToolUse 要等岛上的决策。
        #
        # 90 秒是超时阶梯（HookTimeouts）的最外层，必须大于 hubctl 的 75 秒读超时：
        # 如果 Claude 在 hubctl 输出拒绝之前就把它杀掉，那等同于没有输出，
        # 也就是**放行** —— 正好是安全默认值的反面。
        hook["timeout"] = timeout
    else:
        # async: true 很关键 —— 旧配置是 false 且 hook 里同步 afplay，
        # 导致每轮回复结束都被阻塞。
        hook["async"] = True
    entries.append({"hooks": [hook]})
    hooks[event] = entries

# 全部九类 hook 都装上。
#
# 只装用得着的那几类是个诱人的省事做法，但它让"这一类到底通不通"无从判断 ——
# 收不到事件时分不清是"没装"还是"装了但链路断了"。全装上之后，
# 设置页的通道健康度才有意义：每一行要么亮过，要么就是真有问题。
#
# ⚠️ UserPromptSubmit / SessionStart 的 stdout 会被 Claude 当成**附加 context
# 注入进对话**。hubctl 在这些链路上一个字都不往 stdout 打，
# async: True 是第二道保险（异步 hook 的输出会被直接忽略）。
install("SessionStart", "sessionstart", blocking=False)
install("UserPromptSubmit", "userprompt", blocking=False)
install("PreToolUse", "pretool", blocking=True)
install("PostToolUse", "posttool", blocking=False)
install("Notification", "notification", blocking=False)
# Stop 是阻塞的：Hub 要在这里判断该不该把验收清单塞回去。
#
# 10 秒而不是 90 —— 它挡在**每一次收工**前面，Hub 一卡住用户就干等。
# 判断本身是查内存，毫秒级；这 10 秒纯粹是异常时的上界。
# 超时被杀掉等同于没有输出，也就是正常收工，方向是安全的。
install("Stop", "stop", blocking=True, timeout=10)
install("SubagentStop", "subagentstop", blocking=False)
install("PreCompact", "precompact", blocking=False)
install("SessionEnd", "sessionend", blocking=False)

with open(path, "w") as handle:
    json.dump(settings, handle, indent=2, ensure_ascii=False)
    handle.write("\n")

print("已配置 9 类 hook：SessionStart / UserPromptSubmit / PreToolUse / PostToolUse")
print("                  Notification / Stop / SubagentStop / PreCompact / SessionEnd")
PYTHON

ok "已更新 $SETTINGS"

# ---------- 自检 ----------

echo
log "自检"
if "$HUBCTL" doctor; then
  ok "Claude Hub 正在运行，hook 链路已通"
else
  warn "Claude Hub 没在运行 —— hook 会全部放行（fail-open，不会卡住 Claude）"
  echo '  启动：open -a "Claude Hub"'
fi

echo
ok "完成。新开的 Claude 会话会自动生效；已有会话需要重启才会读到新配置。"

# 从 dmg 双击运行时终端窗口会立刻消失，看不到上面这些输出。
if [ -z "$HUB_DIR" ] && [ -t 0 ]; then
  echo
  read -r -p "按回车关闭…" _
fi
