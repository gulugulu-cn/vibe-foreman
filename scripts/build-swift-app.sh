#!/bin/bash
# 构建 Claude Hub.app（SwiftUI 版）。
#
# 用 SwiftPM + 手工组装 bundle，而不是 .xcodeproj：
# - 手写 xcodeproj 的 XML 极易出错且几乎无法 code review；
# - SwiftPM 保住了 `swift test`（84 个测试）；
# - 和这个脚本原有的签名策略是一路的。
#
# 签名策略（沿用 Rust 版 build-app.sh 的做法，必须保留）：
#   固定自签名证书 + 固定 bundle identifier
# 这样 macOS 的 TCC 授权（Automation 控制 iTerm、通知权限）在重新编译后
# 不会失效。换证书或换 identifier 都会让用户每次重编都要重新授权一遍。

set -euo pipefail

HUB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG_DIR="${HUB_DIR}/HubKit"
APP_NAME="Vibe Foreman Free"
BUNDLE_ID="dev.hengjun.claude-hub"
CERT_NAME="Claude Hub Dev"
CONFIG="${1:-release}"

if [ "$CONFIG" = "release" ]; then
  BUILD_DIR="$PKG_DIR/.build/release"
else
  BUILD_DIR="$PKG_DIR/.build/debug"
fi
# 暂存目录，组装 + 签名在这里做，装完就删。
#
# **不能留一份长期存在的副本**（原来放在 dist/）：LaunchServices 会把每一个
# .app 都按 bundle identifier 注册，同一个 id 对应多个 bundle 时，
# `open -b` 打开哪一个不可预期、通知和 TCC 授权会互相抢 —— 这正是这次
# 要修的原始问题（当时 /Applications、Tauri 构建产物、dist/ 三份同 id）。
APP_PATH="${PKG_DIR}/.build/stage/${APP_NAME}.app"

log() { printf '\033[36m▸\033[0m %s\n' "$1"; }
fail() { printf '\033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }

# ---------- 环境检查 ----------

command -v swift >/dev/null || fail "找不到 swift，请先安装 Xcode"
xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1 \
  || fail "Xcode 首次启动检查未通过，请先运行：sudo xcodebuild -runFirstLaunch"

SDK_VERSION=$(xcrun --show-sdk-version)
MAJOR=${SDK_VERSION%%.*}
if [ "$MAJOR" -lt 26 ]; then
  fail "需要 macOS 26 SDK（当前 ${SDK_VERSION}）。灵动岛依赖 Liquid Glass API。"
fi

# ---------- 编译 ----------

# 变量名后面紧跟中文标点时必须用花括号：bash 会把全角逗号的字节
# 当成变量名的一部分，报 "CONFIG?: unbound variable"。
log "编译（${CONFIG}，SDK ${SDK_VERSION}）…"
cd "$PKG_DIR"
swift build -c "$CONFIG" --product ClaudeHub
swift build -c "$CONFIG" --product hubctl

[ -f "$BUILD_DIR/ClaudeHub" ] || fail "没找到构建产物 $BUILD_DIR/ClaudeHub"

# ---------- 组装 bundle ----------

log "组装 ${APP_NAME}.app…"
rm -rf "${APP_PATH}"
mkdir -p "${APP_PATH}/Contents/MacOS" "${APP_PATH}/Contents/Resources"

cp "$BUILD_DIR/ClaudeHub" "${APP_PATH}/Contents/MacOS/ClaudeHub"

# hubctl 放 Contents/Helpers/ 而**不是** Contents/MacOS/。
#
# 实测教训：放在 MacOS/ 里并且和主程序共用同一个 bundle identifier 时，
# macOS 会在 exec 的瞬间 SIGKILL 它（Apple Silicon 上签名不匹配就是直接杀，
# 表现为 "EXIT=137"，没有任何错误信息）。MacOS/ 目录约定只放
# CFBundleExecutable 指向的那一个可执行文件，辅助工具应该放 Helpers/。
mkdir -p "${APP_PATH}/Contents/Helpers"
cp "$BUILD_DIR/hubctl" "${APP_PATH}/Contents/Helpers/hubctl"

if [ -f "${HUB_DIR}/Resources/AppIcon.icns" ]; then
  cp "${HUB_DIR}/Resources/AppIcon.icns" "${APP_PATH}/Contents/Resources/AppIcon.icns"
fi

cat > "${APP_PATH}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>       <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>        <string>ClaudeHub</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>2.5.0</string>
    <key>CFBundleVersion</key>           <string>2</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>    <string>26.0</string>
    <!-- 托盘 app：不在 Dock 显示，也不占应用切换器位置 -->
    <key>LSUIElement</key>               <true/>
    <!-- 控制 iTerm 切 tab 需要 Automation 权限，这条是授权弹窗里的说明文案 -->
    <key>NSAppleEventsUsageDescription</key>
    <string>Vibe Foreman Free 需要控制终端来跳转到对应的会话标签页。</string>
</dict>
</plist>
PLIST

# ---------- 签名 ----------

# 签名顺序很重要：**先签嵌套的可执行文件，再签外层 bundle**。
#
# 不能用 `--deep`：它会把外层的 --identifier 强加到 hubctl 上，
# 两个不同的二进制声称同一个 bundle identifier，exec 时会被直接 SIGKILL。
#
# 也不加 `--options runtime`（hardened runtime）：自签名 + 未公证的情况下
# 它不提供任何实际保护，反而会引入额外的加载限制。
sign_one() {
  local target="$1" identifier="$2"
  if [ -n "$SIGN_IDENTITY" ]; then
    codesign --force --sign "$SIGN_IDENTITY" --identifier "$identifier" "$target"
  else
    codesign --force --sign - --identifier "$identifier" "$target"
  fi
}

if ! security find-certificate -c "${CERT_NAME}" >/dev/null 2>&1; then
  SIGN_IDENTITY=""
  log "未找到自签名证书「${CERT_NAME}」"
  cat <<'HINT'

  首次构建需要创建一个自签名证书，这样 TCC 授权（控制 iTerm、发通知）
  在每次重新编译后仍然有效，不用反复授权。

  手动创建一次即可：
    1. 打开「钥匙串访问」
    2. 菜单：钥匙串访问 → 证书助理 → 创建证书…
    3. 名称填：Claude Hub Dev
    4. 身份类型：自签名根证书
    5. 证书类型：代码签名
    6. 创建

  没有证书时会退回 ad-hoc 签名，功能正常，但每次重编都要重新授权。

HINT
  log "本次使用 ad-hoc 签名"
else
  SIGN_IDENTITY="${CERT_NAME}"
  log "用「${CERT_NAME}」签名…"
fi

# 内层：hubctl 用自己的 identifier。
sign_one "${APP_PATH}/Contents/Helpers/hubctl" "${BUNDLE_ID}.hubctl"
# 外层：bundle 用主 identifier。此时会把 Helpers/ 的内容封进 CodeResources。
sign_one "${APP_PATH}" "$BUNDLE_ID"

codesign --verify --verbose=1 "${APP_PATH}" 2>&1 | sed 's/^/  /'
codesign --verify --verbose=1 "${APP_PATH}/Contents/Helpers/hubctl" 2>&1 | sed 's/^/  /'

# 冒烟测试：确认 hubctl 真的能跑起来。签名不对的话它会被瞬间 SIGKILL，
# 而那种失败没有任何错误输出，不主动测就会一路带到用户那里。
if "${APP_PATH}/Contents/Helpers/hubctl" doctor >/dev/null 2>&1 || [ $? -eq 1 ]; then
  log "hubctl 冒烟测试通过"
else
  fail "hubctl 无法执行（退出码 $?）—— 多半是签名问题"
fi

# ---------- 安装到 /Applications ----------
#
# 必须装进 /Applications 而不是从 dist/ 直接跑。
#
# 踩过的坑：仓库里曾经同时存在三个 bundle 都叫 dev.hengjun.claude-hub
# （/Applications 里的旧 Tauri 版、Tauri 的构建产物、dist/ 里的新版）。
# 同一个 bundle identifier 对应多个 .app 时：
#   - LaunchServices 注册多条记录，`open -b` 打开哪一个不可预期；
#   - UNUserNotificationCenter 的授权和 TCC 授权是按 identifier 存的，两个 app 互相抢；
#   - 任何 `pgrep -f "Claude Hub.app"` 式的存活判断都会误匹配。
# 所以：一个 identifier 只允许对应 /Applications 里那一个 bundle。
INSTALL_PATH="/Applications/${APP_NAME}.app"
# 改过显示名，旧名字那份必须清掉 —— 留着的话 /Applications 里同时躺着
# 两个功能一样的 app，而它们共用同一个 bundle id，`open -a` 开哪个全看运气。
LEGACY_PATH="/Applications/Claude Hub.app"
[ -d "$LEGACY_PATH" ] && [ "$LEGACY_PATH" != "$INSTALL_PATH" ] && rm -rf "$LEGACY_PATH"

log "安装到 ${INSTALL_PATH}…"
# 先退掉正在跑的旧实例，否则覆盖正在执行的二进制会得到一个半死不活的进程。
if pgrep -x ClaudeHub >/dev/null 2>&1; then
  pkill -x ClaudeHub
  # 等它真的退出。SIGTERM 后 applicationWillTerminate 要收尾 socket 和 tmux 监听。
  for _ in $(seq 1 20); do
    pgrep -x ClaudeHub >/dev/null 2>&1 || break
    sleep 0.2
  done
  log "已退出正在运行的实例"
fi

rm -rf "${INSTALL_PATH}"
cp -R "${APP_PATH}" "${INSTALL_PATH}"
# 暂存副本必须删掉，理由见 APP_PATH 处的说明。
rm -rf "${APP_PATH}"

log "完成：${INSTALL_PATH}"
echo
echo "  启动：open -a '${APP_NAME}'"
echo "  安装 hook：bash '${HUB_DIR}/scripts/setup-swift-hooks.sh'"
