#!/bin/bash
# DeskIsle 打包脚本：把 release 二进制打包成可双击运行的 DeskIsle.app
#
# 用法：
#   cd mac && bash build-app.sh
#
# 签名（重要）：
#   默认走 ad-hoc 签名（`codesign --sign -`），本机可以正常运行。
#   但 **ad-hoc 签名每次重建都会改变应用身份**，macOS 会把「辅助功能」「输入监控」
#   等隐私授权视为新应用 —— 表现为每次重新打包后都要去系统设置里重新勾选一次。
#
#   若要授权保持有效，请用一张**固定的自签证书**签名：
#     1) 「钥匙串访问」→ 证书助理 → 创建证书…
#        名称 DeskIsle Dev，身份类型「自签名根证书」，证书类型「代码签名」
#     2) 之后用：DESKISLE_SIGN_IDENTITY="DeskIsle Dev" bash build-app.sh
#   脚本也会自动识别名称里含 DeskIsle 的代码签名证书，无需每次手写环境变量。
set -eo pipefail

cd "$(dirname "$0")"

APP_NAME="DeskIsle"
BUNDLE_ID="com.deskisle.app"
BUILD_DIR=".build/release"
APP_DIR="dist/${APP_NAME}.app"
VERSION="0.1.0"

echo "==> 1/5 运行测试（排版基准回归）"
# 排版核心（Layout / PartitionMetrics / LayoutEngine）的断言。
# 失败说明改动破坏了基准，先修测试再打包。
swift test --disable-sandbox 2>&1 | tail -3

echo "==> 2/5 编译 release 版本"
swift build -c release --disable-sandbox

echo "==> 3/5 清理并创建 .app 目录结构"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources/zh_CN.lproj"
mkdir -p "${APP_DIR}/Contents/Resources/en.lproj"

echo "==> 4/5 复制二进制与资源 + 生成 Info.plist"
cp "${BUILD_DIR}/${APP_NAME}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"

# 复制应用图标
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "${APP_DIR}/Contents/Resources/AppIcon.icns"
fi

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>zh_CN</string>
        <string>en</string>
    </array>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>DeskIsle 桌岛</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>DeskIsle</string>
</dict>
</plist>
PLIST

echo "==> 5/5 签名"
# 身份优先级：环境变量 > 钥匙串中含 DeskIsle 的证书 > ad-hoc 兜底
SIGN_IDENTITY="${DESKISLE_SIGN_IDENTITY:-}"
if [ -z "${SIGN_IDENTITY}" ]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -F "DeskIsle" | head -1 | sed -E 's/^[^"]*"([^"]*)".*$/\1/') || true
fi

if [ -n "${SIGN_IDENTITY}" ]; then
    echo "    使用固定签名身份：${SIGN_IDENTITY}"
    # 不再使用 --deep（Apple 已弃用，且对含嵌套代码的 bundle 不可靠）
    if codesign --force --sign "${SIGN_IDENTITY}" "${APP_DIR}" 2>/dev/null; then
        echo "    ✓ 授权可在重新打包后保持有效"
    else
        echo "    ✗ 用该身份签名失败，回退 ad-hoc"
        SIGN_IDENTITY=""
    fi
fi

if [ -z "${SIGN_IDENTITY}" ]; then
    codesign --force --sign - "${APP_DIR}" 2>/dev/null || echo "    (签名跳过，不影响本机运行)"
    echo ""
    echo "    ⚠️ 当前为 ad-hoc 签名：每次重新打包后，"
    echo "       「系统设置 → 隐私与安全性 → 辅助功能 / 输入监控」里的授权可能失效，"
    echo "       需要手动重新勾选 DeskIsle。"
    echo "       如需保持授权，请创建一张自签代码签名证书（见本脚本头部注释）。"
fi

# 签名有效性校验（ad-hoc 也应当可验证）
if codesign --verify --strict "${APP_DIR}" 2>/dev/null; then
    echo "    ✓ 签名校验通过"
else
    echo "    ⚠️ 签名校验未通过（不影响本机运行，但重新授权可能更频繁）"
fi

echo ""
echo "打包完成：${APP_DIR}（v${VERSION}）"
echo "双击运行：open ${APP_DIR}"
