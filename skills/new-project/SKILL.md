---
name: new-project
description: Use when user wants to create a new project/repo (新建项目、建仓、快速创建 git 项目). One command creates directory + git init + GitHub remote (public/private) + anti-pollution .claude/settings.json + registers into claude-hub projects.yaml.
---

# 一键创建新项目

把「建项目」压成一条命令：目录 → git init（main 分支）→ 首次提交 → GitHub 建仓并推送 → 写防污染配置 → 注册进 hub 的 projects.yaml。

## 执行方式

```bash
bash ~/Documents/code/claude-hub/scripts/new-project.sh <name> [选项]
```

| 选项 | 含义 | 默认 |
|------|------|------|
| `--dir <parent>` | 父目录 | `~/Documents/code` |
| `--private` / `--public` | GitHub 仓可见性 | 私有 |
| `--no-remote` | 只建本地仓，不建 GitHub 远程 | 建远程 |
| `--no-deny` | 不写防污染 deny 配置 | 写 |
| `--desc "<text>"` | 项目描述（进 README） | 空 |

示例：

```bash
# 在 ~/Documents/code/shopify 下建私有项目
bash ~/Documents/code/claude-hub/scripts/new-project.sh feed-sync --dir ~/Documents/code/shopify --desc "Feed 同步服务"

# 公开仓
bash ~/Documents/code/claude-hub/scripts/new-project.sh my-tool --public
```

## 使用规则（对 Claude）

1. 用户说"新建项目 xxx"/"建个仓"时，从对话里提取：**项目名、父目录、公开/私有、描述**。
2. 项目名没给就必须先问，不要猜。公开/私有没说默认**私有**（可顺口确认）。
3. 直接执行脚本，把输出里的 remote 地址报给用户。
4. 脚本失败时按 stderr 里的补救命令处理，不要自己另起一套 git 命令重做。

## 防污染 deny（默认写入）

`.claude/settings.json` 禁止项目会话 Write/Edit 宿主机 `~/.claude/` 的
agents / skills / commands / projects/*/memory / CLAUDE.md，配套
`autoMemoryDirectory: ./.claude/memory` 让记忆落项目内。

**刻意不禁 `~/.claude/plans/**`**：plan mode 的计划文件写在那里，禁了它所有
plan 会话都会报 "Error writing file"（在 agentx-dev-kit 真踩过）。如果用户
点名要求把 plans 也禁掉，先把这个坑讲给他听再动手。
