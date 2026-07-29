#!/bin/bash
# claude-hub 初始化脚本
# 在新电脑上运行一次即可：bash scripts/setup.sh
#
# 1. 注入全局 hooks（Stop + Notification）
# 2. 确保脚本有执行权限
# 3. 验证配置

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

HUB_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SETTINGS_FILE="$HOME/.claude/settings.json"

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  Claude 调度中心 - 初始化${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# 确保 ~/.claude 目录和 settings.json 存在
mkdir -p "$HOME/.claude"
if [ ! -f "$SETTINGS_FILE" ]; then
  echo '{}' > "$SETTINGS_FILE"
  echo -e "${YELLOW}创建了 $SETTINGS_FILE${NC}"
fi

# 注入 hooks
#
# 这里**不再自己写 settings.json**，一律转交 setup-swift-hooks.sh。
#
# 原因：这个脚本以前会注入 hub-hook-stop.sh / hub-hook-permission.sh 那套 bash hook。
# 它们和现在的 hubctl 是互斥的两套实现，而且这个脚本跑在后面就会把 hubctl 的配置
# 覆盖回去 —— 「装完 hook 又不生效」的经典来源。配置只允许有一个出口。
if ! bash "$HUB_DIR/scripts/setup-swift-hooks.sh"; then
  echo -e "${RED}✗ hook 配置失败${NC}"
  exit 1
fi

# 初始化 projects.yaml
if [ ! -f "$HUB_DIR/projects.yaml" ]; then
  if [ -f "$HUB_DIR/projects.yaml.example" ]; then
    cp "$HUB_DIR/projects.yaml.example" "$HUB_DIR/projects.yaml"
    echo -e "${YELLOW}已从 example 创建 projects.yaml，请编辑添加你的项目${NC}"
    echo -e "${YELLOW}  或运行: bash scripts/scan-projects.sh ~/Documents/code${NC}"
  fi
else
  echo -e "${GREEN}✓ projects.yaml 已存在${NC}"
fi

# 配置 iTerm2 tmux 集成（命令行直接写 plist，无需手动去 GUI 勾选）
if command -v defaults &>/dev/null; then
  # tmux 窗口显示为 iTerm2 原生标签页（0=Native windows, 2=Tabs in new window）
  defaults write com.googlecode.iterm2 OpenTmuxWindowsIn -int 2
  # 连接后自动隐藏 tmux 控制会话
  defaults write com.googlecode.iterm2 AutoHideTmuxClientSession -bool true
  echo -e "${GREEN}✓ iTerm2 tmux 集成已配置${NC}"
fi

# 确保脚本有执行权限
chmod +x "$HUB_DIR/scripts/"*.sh
echo -e "${GREEN}✓ 脚本权限已设置${NC}"

# 创建信号目录
mkdir -p /tmp/hub-signals
echo -e "${GREEN}✓ 信号目录已创建${NC}"

# 生成语音文件
SOUNDS_DIR="$HUB_DIR/sounds"
mkdir -p "$SOUNDS_DIR"
if [ ! -f "$SOUNDS_DIR/done1.aiff" ]; then
  say -o "$SOUNDS_DIR/done1.aiff" "搞定了，来看看"
  say -o "$SOUNDS_DIR/done2.aiff" "干完了，等你验收"
  say -o "$SOUNDS_DIR/done3.aiff" "这边好了"
  say -o "$SOUNDS_DIR/done4.aiff" "完事儿了"
  say -o "$SOUNDS_DIR/done5.aiff" "做好了，请过目"
  say -o "$SOUNDS_DIR/auth1.aiff" "需要你授权"
  say -o "$SOUNDS_DIR/auth2.aiff" "在等你点确认"
  say -o "$SOUNDS_DIR/auth3.aiff" "卡住了，需要你批准"
  echo -e "${GREEN}✓ 语音文件已生成${NC}"
else
  echo -e "${GREEN}✓ 语音文件已存在${NC}"
fi

# 验证
echo ""
echo -e "${BOLD}验证：${NC}"

for cmd in tmux say osascript terminal-notifier; do
  if command -v $cmd &>/dev/null; then
    echo -e "${GREEN}✓ $cmd 可用${NC}"
  else
    echo -e "${RED}✗ $cmd 不可用${NC}"
  fi
done

for script in hub-run.sh hub-notify.sh project-menu.sh welcome.sh; do
  if [ -f "$HUB_DIR/scripts/$script" ]; then
    echo -e "${GREEN}✓ $script${NC}"
  else
    echo -e "${YELLOW}⚠ $script 不存在${NC}"
  fi
done

echo ""
echo -e "${GREEN}${BOLD}初始化完成！${NC}"
echo ""
echo -e "全局 hook 已配置："
echo -e "  ${CYAN}Stop${NC}         → 灵动岛闯入提示 + 可点击跳转的通知"
echo -e "  ${CYAN}Notification${NC} → Claude 需要输入/授权时提示"
echo -e "  ${CYAN}SessionEnd${NC}   → 会话结束时清理岛上的条目"
echo -e "  ${CYAN}PreToolUse${NC}   → 高风险操作在岛上审批"
echo ""
echo -e "${YELLOW}子窗口的 Claude 需要重启才能生效。${NC}"

# 编译并安装 app
if [ ! -d "/Applications/Claude Hub.app" ]; then
  echo ""
  echo -e "${YELLOW}Claude Hub.app 尚未安装，正在编译（首次需要几分钟）...${NC}"
  bash "$HUB_DIR/scripts/build-swift-app.sh"
else
  echo -e "${GREEN}✓ Claude Hub.app 已安装${NC}"
fi
