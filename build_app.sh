#!/usr/bin/env bash
set -euo pipefail

APP_NAME="MacDesktopNotify"
BUNDLE_ID="com.yeheng.macdesktopnotify"
# CI 从 tag 注入版本（v1.2.3 → 1.2.3）；本地构建沿用默认值。
VERSION="${VERSION:-1.1.0}"
MIN_MACOS_VERSION="14.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"

echo "🧹 清理旧构建..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${BUILD_DIR}"

echo "🔨 编译 Release 版本..."
cd "${SCRIPT_DIR}"
swift build -c release --build-path "${BUILD_DIR}"

echo "📦 创建 App Bundle..."
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

# 查找可执行文件（SPM --build-path 的产物在 out/Products/<Config>/ 下，且
# build/release 是指向它的符号链接；不带 -L 的 find 看不到链接指向的内容，
# -maxdepth 3 也够不到 out/Products/Release 这一层）。
EXE_PATH=$(find -L "${BUILD_DIR}" -maxdepth 4 -type f -name "${APP_NAME}" | grep -E "Products/Release" | head -n 1)
if [[ -z "${EXE_PATH}" ]]; then
    echo "❌ 找不到可执行文件"
    exit 1
fi

echo "   可执行文件: ${EXE_PATH}"
cp "${EXE_PATH}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

# SPM 把内置的 styles 打成可执行文件旁的 resource bundle；手工拼装的
# .app 必须把它搬进 Contents/Resources。少了它内置预设会全部消失（BuiltinConfigs
# 已做非致命兜底，不会像 Bundle.module 那样 fatalError），但这显然不是想要的包。
RESOURCE_BUNDLE=$(find -L "${BUILD_DIR}" -maxdepth 4 -type d -name "${APP_NAME}_${APP_NAME}.bundle" | grep -E "Products/Release" | head -n 1)
if [[ -z "${RESOURCE_BUNDLE}" ]]; then
    echo "❌ 找不到内置配置 resource bundle：${APP_NAME}_${APP_NAME}.bundle"
    exit 1
fi
echo "   内置配置: ${RESOURCE_BUNDLE}"
rm -rf "${APP_BUNDLE}/Contents/Resources/${APP_NAME}_${APP_NAME}.bundle"
cp -R "${RESOURCE_BUNDLE}" "${APP_BUNDLE}/Contents/Resources/"
if [[ ! -d "${APP_BUNDLE}/Contents/Resources/${APP_NAME}_${APP_NAME}.bundle/Contents/Resources/styles" ]]; then
    echo "❌ 内置配置复制失败，.app 将没有内置 styles"
    exit 1
fi

echo "📝 生成 Info.plist..."
cat > "${APP_BUNDLE}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_MACOS_VERSION}</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>${BUNDLE_ID}.push</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>notch-notify</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

echo "🔏 Ad-hoc 签名..."
codesign --force --deep --sign - "${APP_BUNDLE}" 2>/dev/null || echo "   签名跳过"

echo ""
echo "✅ 打包完成: ${APP_BUNDLE}"
echo ""
echo "启动方式:"
echo "   双击:    open '${APP_BUNDLE}'"
echo "   命令行:  '${APP_BUNDLE}/Contents/MacOS/${APP_NAME}'"
echo ""
