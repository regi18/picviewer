#!/bin/sh
# Builds PicViewer.app into build/ (no Xcode project needed). Pass --install to also copy it to /Applications.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/PicViewer.app"
VERSION="${VERSION:-1.0}"
BUNDLE_ID="${BUNDLE_ID:-io.github.simone.picviewer}"

# The macOS 27 SDK turns @State into a macro whose plugin only ships with Xcode; the 26.5 SDK does not.
CLT_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
if [ -z "${SDKROOT:-}" ] && [ -d "$CLT_SDK" ] && [ "$(xcode-select -p)" = "/Library/Developer/CommandLineTools" ]; then
    export SDKROOT="$CLT_SDK"
fi

cd "$ROOT"
swift build -c release --product PicViewer
BIN="$(swift build -c release --show-bin-path)/PicViewer"

if [ ! -f "$ROOT/Resources/AppIcon.icns" ]; then
    sh "$ROOT/scripts/make-icon.sh"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# SwiftPM records the deployment target (14.0) as the SDK the app was built with. macOS only gives an app the
# current look (Liquid Glass toolbar and controls) when the binary says it was built with a current SDK, so stamp
# in the real SDK version.
MINOS="$(vtool -show-build "$BIN" | awk '/minos/ {print $2; exit}')"
SDK="$(xcrun --sdk macosx --show-sdk-version)"
vtool -set-build-version macos "${MINOS:-14.0}" "$SDK" -replace -output "$APP/Contents/MacOS/PicViewer" "$BIN"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>PicViewer</string>
    <key>CFBundleDisplayName</key><string>PicViewer</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>PicViewer</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>PicViewer asks Finder how the folder is sorted, so pictures appear in the same order as in Finder.</string>
    <key>NSDesktopFolderUsageDescription</key><string>PicViewer shows the pictures in the folder you opened.</string>
    <key>NSDocumentsFolderUsageDescription</key><string>PicViewer shows the pictures in the folder you opened.</string>
    <key>NSDownloadsFolderUsageDescription</key><string>PicViewer shows the pictures in the folder you opened.</string>
    <key>NSRemovableVolumesUsageDescription</key><string>PicViewer shows the pictures in the folder you opened.</string>
    <key>NSNetworkVolumesUsageDescription</key><string>PicViewer shows the pictures in the folder you opened.</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Image</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.image</string>
                <string>public.camera-raw-image</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>Folder</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>None</string>
            <key>LSItemContentTypes</key>
            <array><string>public.folder</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Ad-hoc signature so Gatekeeper runs the locally built app without a developer account.
codesign --force --deep --sign - "$APP"
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
    rm -rf "/Applications/PicViewer.app"
    cp -R "$APP" /Applications/
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/PicViewer.app
    echo "Installed /Applications/PicViewer.app"
fi
