#!/bin/zsh
# Builds ATC House.app into ./build. Usage: ./build.sh [--install]
set -e
cd "$(dirname "$0")"
swift build -c release --arch arm64 --arch x86_64   # runs on Apple Silicon and Intel
BIN=.build/apple/Products/Release/ATCHouse
APP="build/ATC House.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/"
# App icon from Resources/icon-1024.png (regenerate: swift scripts/make-icon.swift Resources/icon-1024.png)
SET=build/AppIcon.iconset; rm -rf $SET; mkdir -p $SET
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/icon-1024.png --out $SET/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) Resources/icon-1024.png --out $SET/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns $SET -o "$APP/Contents/Resources/AppIcon.icns"
cp Sources/ATCHouse/Resources/sets.json "$APP/Contents/Resources/" 2>/dev/null || echo '[]' > "$APP/Contents/Resources/sets.json"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>ATC House</string>
  <key>CFBundleIdentifier</key><string>com.mckee.atchouse</string>
  <key>CFBundleExecutable</key><string>ATCHouse</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"
(cd build && rm -f ATC-House.zip && ditto -c -k --keepParent "ATC House.app" ATC-House.zip) && echo "Zip: build/ATC-House.zip"
if [[ "$1" == "--install" ]]; then
  rm -rf "/Applications/ATC House.app" && cp -R "$APP" /Applications/ && echo "Installed to /Applications"
fi
