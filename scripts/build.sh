#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
swift build -c release --cache-path "$PWD/.build/cache" --scratch-path "$PWD/.build"
BIN_DIR=$(swift build -c release --show-bin-path --cache-path "$PWD/.build/cache" --scratch-path "$PWD/.build")
APP="$PWD/dist/MacStatus.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MacStatus" "$APP/Contents/MacOS/MacStatus"
cp Resources/Info.plist "$APP/Contents/Info.plist"
"$APP/Contents/MacOS/MacStatus" --export-icon "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "Built: $APP"
