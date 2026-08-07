#!/usr/bin/env bash
# 确保一个项目的 .claude/settings.json 是完整的：防污染 deny + 全套 hook。
#
# 用法：bash ensure-project-config.sh <项目目录>
#
# 幂等：已经对的不动，缺的补上，用户自己加的东西一律保留。
# 不阻断：补不上也只是打一行，绝不让项目起不来。
#
# ── 为什么项目级也要写 hook ─────────────────────────────────────────
#
# 全局 ~/.claude/settings.json 已经有一套了。项目级这一份的价值是：
# 配置跟着仓库走，换机器、别人 clone 下来，这个项目的要求是自带的，
# 不依赖某台机器上装没装过。
#
# ⚠️ 但 Claude Code 的 hook 是**叠加执行**的（本机实测：项目级和全局的
# 同名 hook 会各跑一遍），所以同一个事件会进 Hub 两次。这一点由 Hub 侧的
# HookDedup 兜住 —— 没有它就不能开项目级 hook，否则验收拦截的「上膛」
# 会被重复事件消费掉，拦截静默失效。改这里之前先确认那边还在。
set -euo pipefail

DIR="${1:-$PWD}"
HUBCTL="$HOME/.local/bin/hubctl"

[ -d "$DIR" ] || { echo "目录不存在：$DIR" >&2; exit 0; }

# hubctl 不在就别写 hook —— 写了每次触发都是 command not found，
# 满屏报错比没有 hook 更糟。deny 那部分照写不误。
WITH_HOOKS=1
[ -x "$HUBCTL" ] || WITH_HOOKS=0

mkdir -p "$DIR/.claude/memory"
[ -f "$DIR/.claude/memory/.gitkeep" ] || touch "$DIR/.claude/memory/.gitkeep"

SETTINGS="$DIR/.claude/settings.json"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

HUBCTL="$HUBCTL" WITH_HOOKS="$WITH_HOOKS" python3 - "$SETTINGS" <<'PYTHON'
import json, os, sys

path = sys.argv[1]
hubctl = os.environ["HUBCTL"]
with_hooks = os.environ["WITH_HOOKS"] == "1"

try:
    with open(path) as handle:
        settings = json.load(handle)
    if not isinstance(settings, dict):
        raise ValueError
except Exception:
    # 坏掉的 settings.json 不能让整个流程停下，但也不能默默盖掉用户的东西。
    os.rename(path, path + ".broken")
    settings = {}
    print("  原 settings.json 解析不了，已改名为 settings.json.broken")

changed = []

# ── 防污染 deny ────────────────────────────────────────────────
#
# 只写 Edit 规则、不写 Write 规则：Edit(path) 已经覆盖所有文件编辑工具（含 Write），
# 而单独的 Write(path) 规则不被权限检查识别，加了只会每次调用都刷警告。
#
# ⚠️ ~/.claude/plans/ 绝不能列进来 —— plan mode 的计划文件就写在那里，
# 禁了它所有 plan 会话都会报 Error writing file（真踩过）。
REQUIRED_DENY = [
    "Edit(~/.claude/agents/**)",
    "Edit(~/.claude/skills/**)",
    "Edit(~/.claude/commands/**)",
    "Edit(~/.claude/projects/*/memory/**)",
    "Edit(~/.claude/CLAUDE.md)",
]

permissions = settings.setdefault("permissions", {})
deny = permissions.setdefault("deny", [])
missing = [rule for rule in REQUIRED_DENY if rule not in deny]
if missing:
    deny.extend(missing)
    changed.append(f"deny 补了 {len(missing)} 条")

# deny 与 autoMemoryDirectory 必须成对存在 —— 只禁不给去处等于把记忆扔了。
if settings.get("autoMemoryDirectory") != "./.claude/memory":
    settings["autoMemoryDirectory"] = "./.claude/memory"
    changed.append("补上 autoMemoryDirectory")

# ── hook ──────────────────────────────────────────────────────
HOOKS = [
    ("SessionStart", "sessionstart", False),
    ("UserPromptSubmit", "userprompt", False),
    ("PreToolUse", "pretool", True),
    ("PostToolUse", "posttool", False),
    ("Notification", "notification", False),
    ("Stop", "stop", False),
    ("SubagentStop", "subagentstop", False),
    ("PreCompact", "precompact", False),
    ("SessionEnd", "sessionend", False),
]

if with_hooks:
    hooks = settings.setdefault("hooks", {})
    fixed = 0
    for event, argument, blocking in HOOKS:
        command = f"{hubctl} hook {argument}"
        entries = [
            entry for entry in (hooks.get(event) or [])
            if not any("hubctl hook" in h.get("command", "") for h in entry.get("hooks", []))
        ]
        hook = {"type": "command", "command": command}
        if blocking:
            hook["timeout"] = 90
        else:
            hook["async"] = True
        entries.append({"hooks": [hook]})
        if hooks.get(event) != entries:
            fixed += 1
        hooks[event] = entries
    if fixed:
        changed.append(f"hook 补了 {fixed} 类")

settings["_doc"] = (
    "由 claude-hub 的 ensure-project-config.sh 维护。deny 防止项目会话写进宿主机 "
    "~/.claude/（全局面，写进去会污染其他项目）；hook 把这个项目接到 Claude Hub 的"
    "验收清单和审批链路上。全局 ~/.claude/settings.json 里也有一套同样的 hook，"
    "两边是叠加执行的，重复事件由 Hub 侧的 HookDedup 去重。"
)

with open(path, "w") as handle:
    json.dump(settings, handle, indent=2, ensure_ascii=False)
    handle.write("\n")

if changed:
    print("  " + "，".join(changed))
else:
    print("  配置已完整")
PYTHON

if [ "$WITH_HOOKS" = 0 ]; then
  echo "  hubctl 没装（$HUBCTL），这次只补了 deny —— 跑一次 setup-swift-hooks.sh 再来"
fi
