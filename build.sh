#!/bin/bash
# Builds "Icecast Control.app" with Icecast and the MP3 encoder inside it.
#
#   ./build.sh             build/Icecast Control.app
#   ./build.sh --install   also copy it to /Applications and open it
#   ./build.sh --release   also make the downloads in dist/:
#                            Icecast-Control.dmg            (the app)
#                            Icecast-Control-OBS-Plugin.zip (separate OBS plugin)
#
# Needs: Xcode command line tools. The first build compiles Icecast and ffmpeg from
# source (a few minutes); later builds reuse them.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Icecast Control"
APP="build/$APP_NAME.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)"

./scripts/build-deps.sh

echo "Building the app..."
swift build -c release --arch arm64

echo "Packaging $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/arm64-apple-macosx/release/IcecastControl" "$APP/Contents/MacOS/IcecastControl"
cp vendor/icecast vendor/ffmpeg "$APP/Contents/MacOS/"
cp -R vendor/icecast-share "$APP/Contents/Resources/icecast"
cp Support/Info.plist "$APP/Contents/Info.plist"
if [[ -f Support/AppIcon.icns ]]; then cp Support/AppIcon.icns "$APP/Contents/Resources/"; fi
cp LICENSE THIRD-PARTY-NOTICES.md "$APP/Contents/Resources/" 2>/dev/null || true

# Local (ad-hoc) signature: helpers first, then the app.
codesign --force --sign - "$APP/Contents/MacOS/icecast" "$APP/Contents/MacOS/ffmpeg"
codesign --force --sign - "$APP"

case "${1:-}" in
--install)
    echo "Installing to /Applications"
    pkill -x IcecastControl 2>/dev/null || true
    sleep 1
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" /Applications/
    open "/Applications/$APP_NAME.app"
    ;;
--release)
    mkdir -p dist
    echo "Making dist/Icecast-Control.dmg"
    STAGE="build/dmg"
    rm -rf "$STAGE" dist/Icecast-Control.dmg
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    cp "Support/Read Me First.txt" "$STAGE/"
    hdiutil create -quiet -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" -ov -format UDZO dist/Icecast-Control.dmg

    echo "Making dist/Icecast-Control-OBS-Plugin.zip"
    rm -f dist/Icecast-Control-OBS-Plugin.zip
    (cd OBS-Plugin && zip -q -r ../dist/Icecast-Control-OBS-Plugin.zip . -x '.*')
    ls -lh dist/
    ;;
esac
echo "Done."
