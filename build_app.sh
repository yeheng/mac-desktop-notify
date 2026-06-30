#!/usr/bin/env bash
set -euo pipefail

APP_NAME="MacDesktopNotify"
BUNDLE_ID="com.yeheng.macdesktopnotify"
VERSION="1.0.0"
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

# 查找可执行文件 (SPM 在自定义 build-path 下会放在 arch-specific 目录中)
EXE_PATH=$(find "${BUILD_DIR}" -maxdepth 3 -type f -name "${APP_NAME}" | grep -E "release/[^/]+$|release/${APP_NAME}$" | head -n 1)
if [[ -z "${EXE_PATH}" ]]; then
    EXE_PATH=$(find "${BUILD_DIR}" -maxdepth 3 -type f -name "${APP_NAME}" | grep release | head -n 1)
fi
if [[ -z "${EXE_PATH}" ]]; then
    echo "❌ 找不到可执行文件"
    exit 1
fi

echo "   可执行文件: ${EXE_PATH}"
cp "${EXE_PATH}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

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
            <string>${BUNDLE_ID}.notify</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>macdesktopnotify</string>
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
