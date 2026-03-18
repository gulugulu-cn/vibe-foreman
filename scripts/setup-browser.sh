#!/bin/bash
# 浏览器双引擎 - 一键安装
#
# 别人拿到 browser-auto skill 后，只需要跑这一条命令：
#   bash setup-browser.sh
#
# 自动完成：
#   1. 安装 skill 到 ~/.claude/skills/（让所有项目的 Claude Code 都能用）
#   2. 配置 chrome-devtools-mcp（User scope + autoConnect）
#   3. 检查 Chrome 环境
#
# 可以从任意位置运行，脚本会自动找到 SKILL.md 的位置。

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

# 找到脚本所在目录和 SKILL.md 位置
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# 支持两种目录结构：
#   结构 A（claude-hub 完整仓库）: scripts/setup-browser.sh → skills/browser-auto/SKILL.md
#   结构 B（独立分发）: setup-browser.sh 和 SKILL.md 在同一目录
if [ -f "$SCRIPT_DIR/../skills/browser-auto/SKILL.md" ]; then
  SKILL_SOURCE="$(cd "$SCRIPT_DIR/../skills/browser-auto" && pwd)"
elif [ -f "$SCRIPT_DIR/SKILL.md" ]; then
  SKILL_SOURCE="$SCRIPT_DIR"
else
  echo -e "${RED}找不到 SKILL.md，请确保脚本和 skill 文件在正确位置${NC}"
  exit 1
fi

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  浏览器双引擎 - 一键安装${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

ERRORS=0
SKILL_DIR="$HOME/.claude/skills/browser-auto"

# ─── 1. 安装 skill ───
echo -e "${BOLD}[1/5] 安装 skill${NC}"

# Claude Code 发现 skill 的优先级：项目级 .claude/skills/ > 用户级 ~/.claude/skills/
# 所以两层都要装：全局兜底 + 当前项目优先

install_skill_link() {
  local target_dir="$1"
  local label="$2"
  mkdir -p "$target_dir"

  if [ -L "$target_dir/SKILL.md" ]; then
    LINK_TARGET=$(readlink "$target_dir/SKILL.md")
    if [ "$LINK_TARGET" = "$SKILL_SOURCE/SKILL.md" ]; then
      echo -e "${GREEN}  ✓ $label 已就绪${NC}"
    else
      rm "$target_dir/SKILL.md"
      ln -s "$SKILL_SOURCE/SKILL.md" "$target_dir/SKILL.md"
      echo -e "${GREEN}  ✓ $label 已更新${NC}"
    fi
  elif [ -f "$target_dir/SKILL.md" ]; then
    rm "$target_dir/SKILL.md"
    ln -s "$SKILL_SOURCE/SKILL.md" "$target_dir/SKILL.md"
    echo -e "${GREEN}  ✓ $label 已替换为符号链接${NC}"
  else
    ln -s "$SKILL_SOURCE/SKILL.md" "$target_dir/SKILL.md"
    echo -e "${GREEN}  ✓ $label 已安装${NC}"
  fi
}

# 全局安装（~/.claude/skills/，所有项目可用）
install_skill_link "$SKILL_DIR" "全局 skill"

# 当前项目安装（如果在 git 项目里，装到 .claude/skills/）
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -n "$PROJECT_ROOT" ] && [ "$PROJECT_ROOT/.claude/skills/browser-auto" != "$SKILL_DIR" ]; then
  install_skill_link "$PROJECT_ROOT/.claude/skills/browser-auto" "项目级 skill ($PROJECT_ROOT)"
fi

# ─── 2. 检查 Chrome 版本 ───
echo -e "${BOLD}[2/5] Chrome 版本${NC}"
if [ -f "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" ]; then
  CHROME_VERSION=$("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --version 2>/dev/null | grep -oE '[0-9]+' | head -1)
  if [ -n "$CHROME_VERSION" ] && [ "$CHROME_VERSION" -ge 144 ]; then
    echo -e "${GREEN}  ✓ Chrome $CHROME_VERSION（>= 144，支持 autoConnect）${NC}"
  elif [ -n "$CHROME_VERSION" ]; then
    echo -e "${YELLOW}  ⚠ Chrome $CHROME_VERSION（< 144，不支持 autoConnect）${NC}"
    echo -e "${YELLOW}    请更新 Chrome，或使用 --browserUrl 模式${NC}"
    ERRORS=$((ERRORS + 1))
  fi
else
  echo -e "${RED}  ✗ 未找到 Google Chrome${NC}"
  ERRORS=$((ERRORS + 1))
fi

# ─── 3. 检查 Claude in Chrome 扩展 ───
echo -e "${BOLD}[3/5] Claude in Chrome 扩展${NC}"
CIC_EXT_DIR="$HOME/Library/Application Support/Google/Chrome/Default/Extensions"
CIC_FOUND=0
for ext_id in fcoeoabgfenejglbffodgkkbkcdhcgfn hbkblmodhbmcakopmmfbaopfckopccgp; do
  if [ -d "$CIC_EXT_DIR/$ext_id" ]; then
    CIC_VERSION=$(ls "$CIC_EXT_DIR/$ext_id/" 2>/dev/null | sort -V | tail -1 | sed 's/_0$//')
    echo -e "${GREEN}  ✓ Claude in Chrome 已安装（v${CIC_VERSION:-unknown}）${NC}"
    CIC_FOUND=1
    break
  fi
done
if [ $CIC_FOUND -eq 0 ]; then
  echo -e "${RED}  ✗ Claude in Chrome 扩展未安装${NC}"
  echo -e "${YELLOW}    请在 Chrome 扩展商店搜索 'Claude in Chrome' 安装${NC}"
  ERRORS=$((ERRORS + 1))
fi

# ─── 4. 配置 chrome-devtools-mcp ───
echo -e "${BOLD}[4/5] chrome-devtools-mcp${NC}"
if ! command -v claude &>/dev/null; then
  echo -e "${RED}  ✗ claude CLI 不可用，请先安装 Claude Code${NC}"
  ERRORS=$((ERRORS + 1))
else
  MCP_INFO=$(claude mcp get chrome-devtools 2>/dev/null)
  if [ $? -eq 0 ]; then
    SCOPE=$(echo "$MCP_INFO" | grep "Scope:" | head -1)
    ARGS=$(echo "$MCP_INFO" | grep "Args:" | head -1)

    # 检查是否配置正确
    HAS_CONNECT=0
    echo "$ARGS" | grep -qE '(autoConnect|browserUrl)' && HAS_CONNECT=1

    if echo "$SCOPE" | grep -q "User" && [ $HAS_CONNECT -eq 1 ]; then
      echo -e "${GREEN}  ✓ 已正确配置（User scope + autoConnect）${NC}"
    else
      if ! echo "$SCOPE" | grep -q "User"; then
        echo -e "${YELLOW}  ⚠ 当前是 Local scope，升级为 User scope（全局生效）${NC}"
        # 移除旧的 local 配置
        claude mcp remove chrome-devtools -s local 2>/dev/null
      fi
      if [ $HAS_CONNECT -eq 0 ]; then
        echo -e "${YELLOW}  ⚠ 缺少 --autoConnect，会启动独立 Chrome${NC}"
        claude mcp remove chrome-devtools -s user 2>/dev/null
      fi
      # 重新配置
      claude mcp add -s user chrome-devtools -- npx chrome-devtools-mcp@latest --autoConnect 2>/dev/null
      if [ $? -eq 0 ]; then
        echo -e "${GREEN}  ✓ 已重新配置（User scope + autoConnect）${NC}"
      else
        echo -e "${RED}  ✗ 配置失败，请手动执行：${NC}"
        echo -e "${CYAN}    claude mcp add -s user chrome-devtools -- npx chrome-devtools-mcp@latest --autoConnect${NC}"
        ERRORS=$((ERRORS + 1))
      fi
    fi
  else
    # 未配置，直接添加
    claude mcp add -s user chrome-devtools -- npx chrome-devtools-mcp@latest --autoConnect 2>/dev/null
    if [ $? -eq 0 ]; then
      echo -e "${GREEN}  ✓ 已配置（User scope + autoConnect）${NC}"
    else
      echo -e "${RED}  ✗ 配置失败，请手动执行：${NC}"
      echo -e "${CYAN}    claude mcp add -s user chrome-devtools -- npx chrome-devtools-mcp@latest --autoConnect${NC}"
      ERRORS=$((ERRORS + 1))
    fi
  fi
fi

# ─── 5. 检查 Chrome remote debugging ───
echo -e "${BOLD}[5/5] Chrome remote debugging${NC}"
CHROME_DEBUG=$(curl -s --connect-timeout 3 http://localhost:9222/json/version 2>/dev/null)
if [ -n "$CHROME_DEBUG" ]; then
  BROWSER_NAME=$(echo "$CHROME_DEBUG" | python3 -c "import sys,json; print(json.load(sys.stdin).get('Browser','unknown'))" 2>/dev/null || echo "unknown")
  echo -e "${GREEN}  ✓ 调试端口已开启（$BROWSER_NAME）${NC}"
else
  echo -e "${YELLOW}  ⚠ Chrome 调试端口未开启${NC}"
  echo -e "${YELLOW}    请在 Chrome 中操作（一次性，重启后依然生效）：${NC}"
  echo -e "${CYAN}    1. 地址栏输入 chrome://inspect/#remote-debugging${NC}"
  echo -e "${CYAN}    2. 点击 'Enable' 开关${NC}"
  ERRORS=$((ERRORS + 1))
fi

# ─── 总结 ───
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
if [ $ERRORS -eq 0 ]; then
  echo -e "${GREEN}${BOLD}  ✓ 安装完成！浏览器双引擎就绪${NC}"
  echo ""
  echo -e "  数据引擎: chrome-devtools-mcp（连接用户日常 Chrome）"
  echo -e "  视觉引擎: Claude in Chrome 扩展"
  echo -e "  skill:    ~/.claude/skills/browser-auto/"
else
  echo -e "${YELLOW}${BOLD}  ⚠ 安装完成，但有 $ERRORS 项需要手动处理${NC}"
  echo ""
  echo -e "  请按上方提示修复后，重新运行此脚本验证。"
fi
echo ""
echo -e "${YELLOW}重启 Claude Code 会话后生效。${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
