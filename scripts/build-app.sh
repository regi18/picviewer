#!/bin/sh
# Builds PicViewer.app into build/ (no Xcode project needed). Pass --install to also copy it to /Applications.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/PicViewer.app"
# CI passes the full release version; local builds use the major.minor from the VERSION file.
VERSION="${VERSION:-$(tr -d '[:space:]' < "$ROOT/VERSION")}"
# Forks should set their own, e.g. BUNDLE_ID=io.github.yourname.picviewer, so their settings are separate.
BUNDLE_ID="${BUNDLE_ID:-io.github.simone.picviewer}"

# The macOS 27 SDK turns @State into a macro whose plugin only ships with Xcode; the 26.5 SDK does not.
# Only pinned when it exists, so CI runners with Xcode keep their own SDK.
CLT_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
if [ -z "${SDKROOT:-}" ] && [ -d "$CLT_SDK" ] && [ "$(xcode-select -p)" = "/Library/Developer/CommandLineTools" ]; then
    export SDKROOT="$CLT_SDK"
fi

cd "$ROOT"
# One build per architecture, each in its own folder because both would otherwise write to the same output path.
# lipo then joins them into a universal app that runs natively on Apple Silicon and Intel.
ARCHITECTURES="arm64 x86_64"
binaries=""
for arch in $ARCHITECTURES; do
    swift build -c release --product PicViewer --triple "$arch-apple-macosx14.0" --scratch-path ".build/$arch"
    binaries="$binaries $(swift build -c release --triple "$arch-apple-macosx14.0" --scratch-path ".build/$arch" --show-bin-path)/PicViewer"
done
BIN="$ROOT/build/PicViewer-universal"
mkdir -p "$ROOT/build"
# $binaries is unquoted on purpose, so each path becomes its own argument.
lipo -create $binaries -output "$BIN"

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
rm -f "$BIN"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# macOS 26 draws app icons in Liquid Glass from an Icon Composer document compiled into Assets.car. A plain .icns still
# works, but the system puts a light rim around it. actool needs Xcode set up (xcodebuild -runFirstLaunch); without it,
# the .icns alone is used.
ICON_WORK="$(mktemp -d)"
if xcrun actool "$ROOT/Resources/AppIcon.icon" --compile "$ICON_WORK" --app-icon AppIcon --platform macosx \
        --minimum-deployment-target "$MINOS" --output-partial-info-plist "$ICON_WORK/partial.plist" >/dev/null 2>&1 \
        && [ -f "$ICON_WORK/Assets.car" ]; then
    cp "$ICON_WORK/Assets.car" "$APP/Contents/Resources/Assets.car"
    [ -f "$ICON_WORK/AppIcon.icns" ] && cp "$ICON_WORK/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
    echo "Icon: Liquid Glass (Assets.car)"
else
    echo "Icon: .icns only. For the Liquid Glass icon, run 'xcodebuild -runFirstLaunch' once and build again"
fi
rm -rf "$ICON_WORK"

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
    <key>CFBundleIconName</key><string>AppIcon</string>
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

# macOS remembers folder permissions per code signature. An ad-hoc signature changes with every build, so each rebuild
# looks like a new app and the permission prompts come back. A self-signed certificate named "PicViewer Local" in the
# login keychain keeps the signature stable across builds (see README); without one, fall back to ad-hoc.
IDENTITY="${PICVIEWER_SIGN_IDENTITY:-PicViewer Local}"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
    codesign --force --deep --sign "$IDENTITY" "$APP"
    echo "Signed with \"$IDENTITY\""
else
    codesign --force --deep --sign - "$APP"
    echo "Signed ad-hoc (no \"$IDENTITY\" certificate): macOS may ask for folder access again after this build"
fi
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
    rm -rf "/Applications/PicViewer.app"
    cp -R "$APP" /Applications/
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/PicViewer.app
    echo "Installed /Applications/PicViewer.app"
fi
