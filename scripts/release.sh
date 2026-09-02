#!/bin/bash
# 打发布包：universal .app + .dmg。
#
# 和 build-swift-app.sh 的分工：
#   build-swift-app.sh  日常开发。只编当前架构，装进 /Applications，几秒钟。
#   release.sh          发布。universal 双架构 + dmg + 校验和，几分钟。
#
# 刻意**不**装进 /Applications：发布构建和你正在用的那个是两回事，
# 打个包不该把你手上跑着的实例换掉。要用新版自己 open dmg 装。

set -euo pipefail

HUB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG_DIR="${HUB_DIR}/HubKit"
APP_NAME="Vibe Foreman Free"
BUNDLE_ID="dev.hengjun.claude-hub"
CERT_NAME="Claude Hub Dev"

VERSION="${1:-}"
if [ -z "${VERSION}" ]; then
  VERSION=$(grep -m1 'CFBundleShortVersionString' "${HUB_DIR}/scripts/build-swift-app.sh" \
    | sed -E 's/.*<string>([^<]+)<\/string>.*/\1/')
fi

# 构建号用提交数，比手工维护可靠：它单调递增，且能反查到具体代码。
BUILD_NUMBER=$(git -C "${HUB_DIR}" rev-list --count HEAD 2>/dev/null || echo 1)
COMMIT=$(git -C "${HUB_DIR}" rev-parse --short HEAD 2>/dev/null || echo "unknown")
DIRTY=""
if ! git -C "${HUB_DIR}" diff --quiet HEAD 2>/dev/null; then DIRTY="+dirty"; fi

STAGE="${PKG_DIR}/.build/release-stage"
APP_PATH="${STAGE}/${APP_NAME}.app"
OUT_DIR="${HUB_DIR}/release"
DMG_PATH="${OUT_DIR}/${APP_NAME// /-}-${VERSION}.dmg"

log() { printf '\033[36m▸\033[0m %s\n' "$1"; }
ok() { printf '\033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '\033[33m!\033[0m %s\n' "$1"; }
fail() { printf '\033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }

# ---------- 环境 ----------

command -v swift >/dev/null || fail "找不到 swift，请先安装 Xcode"
SDK_VERSION=$(xcrun --show-sdk-version)
[ "${SDK_VERSION%%.*}" -ge 26 ] || fail "需要 macOS 26 SDK（当前 ${SDK_VERSION}）"

log "版本 ${VERSION} (build ${BUILD_NUMBER}, ${COMMIT}${DIRTY})"
if [ -n "${DIRTY}" ]; then
  warn "工作区有未提交的改动 —— 这个包对应不到任何一个提交"
fi

# ---------- 测试 ----------
#
# 发布前必须全绿。日常构建可以跳过测试，发布不行。
log "跑测试…"
cd "${PKG_DIR}"
if ! swift test 2>&1 | tail -3; then
  fail "测试没过，不打包"
fi

# ---------- 编译（双架构）----------
#
# `--arch arm64 --arch x86_64` 让 SwiftPM 直接产出 fat binary。
# macOS 26 是最后一个支持 Intel 的版本，还有人在上面跑，所以带上 x86_64。
log "编译 universal（arm64 + x86_64）…"
swift build -c release --arch arm64 --arch x86_64 --product ClaudeHub
swift build -c release --arch arm64 --arch x86_64 --product hubctl

BUILD_DIR="${PKG_DIR}/.build/apple/Products/Release"
[ -f "${BUILD_DIR}/ClaudeHub" ] || fail "没找到构建产物 ${BUILD_DIR}/ClaudeHub"

for binary in ClaudeHub hubctl; do
  archs=$(lipo -archs "${BUILD_DIR}/${binary}")
  case "$archs" in
    *arm64*x86_64*|*x86_64*arm64*) ok "${binary}: ${archs}" ;;
    *) fail "${binary} 不是 universal（${archs}）" ;;
  esac
done

# ---------- 组装 ----------

log "组装 ${APP_NAME}.app…"
rm -rf "${STAGE}"
mkdir -p "${APP_PATH}/Contents/MacOS" \
         "${APP_PATH}/Contents/Resources" \
         "${APP_PATH}/Contents/Helpers"

cp "${BUILD_DIR}/ClaudeHub" "${APP_PATH}/Contents/MacOS/ClaudeHub"
# hubctl 放 Helpers/ 而不是 MacOS/ —— 见 HubKit/NOTES.md，
# 和主程序共用 bundle identifier 会被 exec 瞬间 SIGKILL。
cp "${BUILD_DIR}/hubctl" "${APP_PATH}/Contents/Helpers/hubctl"

# scripts/ 一并打进 Resources/，和 build-swift-app.sh 保持一致。
# dmg 用户**根本没有仓库** —— 不带上这份的话 locateScript 三个仓库候选
# 全落空，ensure-project-config.sh 静默跳过，防污染 deny 一条不补（issue #2）。
mkdir -p "${APP_PATH}/Contents/Resources/scripts"
cp "${HUB_DIR}/scripts/"*.sh "${APP_PATH}/Contents/Resources/scripts/"
chmod +x "${APP_PATH}/Contents/Resources/scripts/"*.sh

[ -f "${HUB_DIR}/Resources/AppIcon.icns" ] \
  && cp "${HUB_DIR}/Resources/AppIcon.icns" "${APP_PATH}/Contents/Resources/AppIcon.icns"

cat > "${APP_PATH}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>       <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>        <string>ClaudeHub</string>
    <key>CFBundleIdentifier</key>        <string>${BUNDLE_ID}</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key>           <string>${BUILD_NUMBER}</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>    <string>26.0</string>
    <key>LSUIElement</key>               <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Vibe Foreman Free 需要控制终端来跳转到对应的会话标签页。</string>
    <!-- 打包时的提交号。用户报问题时能直接对上代码。 -->
    <key>HubGitCommit</key>              <string>${COMMIT}${DIRTY}</string>
</dict>
</plist>
PLIST

# ---------- 签名 ----------
#
# 先签内层再签外层，不用 --deep（理由见 NOTES.md）。
if security find-certificate -c "${CERT_NAME}" >/dev/null 2>&1; then
  SIGN_IDENTITY="${CERT_NAME}"
  log "用「${CERT_NAME}」签名…"
else
  SIGN_IDENTITY="-"
  warn "没有自签名证书「${CERT_NAME}」，退回 ad-hoc 签名"
fi

codesign --force --sign "${SIGN_IDENTITY}" --identifier "${BUNDLE_ID}.hubctl" \
  "${APP_PATH}/Contents/Helpers/hubctl"
codesign --force --sign "${SIGN_IDENTITY}" --identifier "${BUNDLE_ID}" "${APP_PATH}"
codesign --verify --deep --strict "${APP_PATH}" || fail "签名校验失败"
ok "签名通过"

# 冒烟测试：签名不对的话 hubctl 会被瞬间 SIGKILL，而那种失败没有任何输出。
"${APP_PATH}/Contents/Helpers/hubctl" doctor >/dev/null 2>&1 || true
if [ "$?" -gt 1 ]; then fail "hubctl 无法执行 —— 多半是签名问题"; fi
ok "hubctl 冒烟测试通过"

# ---------- dmg ----------

log "打 dmg…"
mkdir -p "${OUT_DIR}"
rm -f "${DMG_PATH}"

DMG_STAGE="${STAGE}/dmg"
rm -rf "${DMG_STAGE}"
mkdir -p "${DMG_STAGE}"
cp -R "${APP_PATH}" "${DMG_STAGE}/"
# 拖进去就装：给个 /Applications 的替身。
ln -s /Applications "${DMG_STAGE}/Applications"
# hook 现在由 app 首次启动时自己装（HookInstaller），dmg 里不再放那个
# 「安装 hook.command」—— 它没有任何用户能做的决定，而漏点它的后果是静默的：
# app 开着、界面正常、一条事件都收不到。
#
# 脚本本身留在仓库里，作为「装坏了怎么手工修」的兜底。
cp "${HUB_DIR}/scripts/setup-swift-hooks.sh" "${DMG_STAGE}/手工修复 hook（通常用不到）.command" 2>/dev/null || true
chmod +x "${DMG_STAGE}/手工修复 hook（通常用不到）.command" 2>/dev/null || true

hdiutil create -volname "${APP_NAME} ${VERSION}" \
  -srcfolder "${DMG_STAGE}" -ov -format UDZO "${DMG_PATH}" >/dev/null
rm -rf "${DMG_STAGE}"

SIZE=$(du -h "${DMG_PATH}" | cut -f1)
SHA=$(shasum -a 256 "${DMG_PATH}" | cut -d' ' -f1)

echo
ok "完成：${DMG_PATH}"
echo "  版本   ${VERSION} (build ${BUILD_NUMBER}, ${COMMIT}${DIRTY})"
echo "  架构   arm64 + x86_64"
echo "  大小   ${SIZE}"
echo "  SHA256 ${SHA}"
echo
cat <<'NOTICE'
分发提醒：这个包是**自签名、未公证**的。
你自己的机器上没问题（证书在你钥匙串里），但别人下载后打开会被 Gatekeeper 拦，
提示"无法打开，因为无法验证开发者"。对方需要：

  右键点 app → 打开 → 再点"打开"

或者在终端里：

  xattr -dr com.apple.quarantine "/Applications/Claude Hub.app"

要做到双击即用，需要 Apple Developer Program（$99/年）的
Developer ID 证书 + notarytool 公证。
NOTICE
