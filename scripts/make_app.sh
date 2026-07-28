#!/bin/bash
# Builds ImageHub.app (universal binary) from the Swift package and wraps it in a DMG.
# Output: dist/ImageHub.app, dist/ImageHub-<version>.dmg, dist/ImageHub-<version>-macos-universal.zip
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="ImageHub"
BUNDLE_ID="com.mac2100.ImageHub"
MIN_MACOS="14.0"

VERSION=$(sed -n 's/.*marketing = "\([^"]*\)".*/\1/p' Sources/ImageHub/Support/AppVersion.swift)
if [ -z "$VERSION" ]; then
  echo "error: could not extract version from AppVersion.swift" >&2
  exit 1
fi
echo "Building ${APP_NAME} ${VERSION}"

ARCH_FLAGS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCH_FLAGS[@]}"
BIN_PATH="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)/${APP_NAME}"

APP="dist/${APP_NAME}.app"
rm -rf dist
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN_PATH}" "${APP}/Contents/MacOS/${APP_NAME}"

# --- App icon -----------------------------------------------------------------
ICONSET="dist/AppIcon.iconset"
mkdir -p "${ICONSET}"
for size in 16 32 128 256 512; do
  sips -z "${size}" "${size}" Resources/icon_1024.png \
    --out "${ICONSET}/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "${double}" "${double}" Resources/icon_1024.png \
    --out "${ICONSET}/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "${ICONSET}" -o "${APP}/Contents/Resources/AppIcon.icns"

# --- Provisioning payload -----------------------------------------------------
# Shared/payload is the canonical copy of the Windows-side scripts; the app
# writes it onto every USB drive it builds, so it has to ride along in the bundle.
cp -R Shared/payload "${APP}/Contents/Resources/payload"
find "${APP}/Contents/Resources/payload" -name '.DS_Store' -delete

# --- Optional bundled wimlib ---------------------------------------------------
# When a universal wimlib-imagex is staged in vendor/bin, ship it so splitting
# large install.wim files works with no Homebrew dependency. Nothing here builds
# it — stage it yourself (e.g. lipo the arm64 and x86_64 Homebrew binaries
# together) and it gets picked up. Without it the app falls back to searching
# Homebrew and /usr/local at runtime.
if [ -x "vendor/bin/wimlib-imagex" ]; then
  mkdir -p "${APP}/Contents/Resources/bin"
  cp vendor/bin/wimlib-imagex "${APP}/Contents/Resources/bin/"
  # wimlib-imagex is normally invoked through per-command symlinks; the app only
  # calls it directly, so the single binary is enough.
  chmod +x "${APP}/Contents/Resources/bin/wimlib-imagex"
  echo "Bundled vendor/bin/wimlib-imagex"
else
  echo "No vendor/bin/wimlib-imagex staged — the app will look for Homebrew's copy at runtime."
fi

# --- Info.plist ---------------------------------------------------------------
cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>${APP_NAME}</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>${APP_NAME}</string>
	<key>CFBundleDisplayName</key>
	<string>${APP_NAME}</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${VERSION}</string>
	<key>LSMinimumSystemVersion</key>
	<string>${MIN_MACOS}</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.utilities</string>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>Open source, MIT licensed.</string>
</dict>
</plist>
PLIST

echo "APPL????" > "${APP}/Contents/PkgInfo"

# Ad-hoc signature so the app runs locally without a developer certificate.
codesign --force --deep --sign - "${APP}"

# --- Zip (plain executable app bundle) ----------------------------------------
ZIP="dist/${APP_NAME}-${VERSION}-macos-universal.zip"
ditto -c -k --sequesterRsrc --keepParent "${APP}" "${ZIP}"

# --- DMG ----------------------------------------------------------------------
STAGING="dist/dmg-staging"
mkdir -p "${STAGING}"
cp -R "${APP}" "${STAGING}/"
ln -s /Applications "${STAGING}/Applications"

DMG="dist/${APP_NAME}-${VERSION}.dmg"
hdiutil create -volname "${APP_NAME}" -srcfolder "${STAGING}" -ov -format UDZO "${DMG}"
rm -rf "${STAGING}" "${ICONSET}"

echo "Built: ${DMG}"
echo "Built: ${ZIP}"
