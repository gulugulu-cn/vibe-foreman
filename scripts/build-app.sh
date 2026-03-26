#!/bin/bash
# 编译 Claude Hub 托盘 app（release 版本）
# 需要：Rust 工具链、Xcode CLT、pkg-config、openssl

CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

HUB_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$HUB_DIR/app/src-tauri"

echo -e "${CYAN}编译 Claude Hub 托盘 app...${NC}"
echo ""

# 检查 Rust
if ! command -v cargo &>/dev/null; then
  echo -e "${YELLOW}未检测到 Rust，正在安装...${NC}"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  source "$HOME/.cargo/env"
fi
echo -e "${GREEN}✓ cargo $(cargo --version | cut -d' ' -f2)${NC}"

# 检查 Xcode CLT（macOS 编译必需）
if ! xcode-select -p &>/dev/null; then
  echo -e "${RED}✗ 需要 Xcode Command Line Tools${NC}"
  echo "  运行: xcode-select --install"
  exit 1
fi
echo -e "${GREEN}✓ Xcode CLT${NC}"

echo ""
cd "$APP_DIR" || { echo -e "${RED}✗ 目录不存在: $APP_DIR${NC}"; exit 1; }
cargo build --release

if [ $? -eq 0 ]; then
  echo ""
  echo -e "${GREEN}✓ 编译完成: $APP_DIR/target/release/claude-hub${NC}"
  echo -e "  架构: $(file "$APP_DIR/target/release/claude-hub" | grep -oE 'arm64|x86_64')"
else
  echo ""
  echo -e "${RED}✗ 编译失败${NC}"
  exit 1
fi
