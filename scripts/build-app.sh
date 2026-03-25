#!/bin/bash
# 编译 Claude Hub 托盘 app（release 版本）
cd ~/Documents/code/claude-hub/app/src-tauri
cargo build --release
echo "✓ 编译完成: target/release/claude-hub"
