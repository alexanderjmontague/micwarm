#!/bin/zsh
# Builds MicWarm.app and installs it to /Applications.
set -e
cd "$(dirname "$0")"
APP=build/MicWarm.app
rm -rf build && mkdir -p $APP/Contents/MacOS
swiftc -O -swift-version 5 main.swift -o $APP/Contents/MacOS/MicWarm
mkdir -p $APP/Contents/Resources
swift make_icon.swift
iconutil -c icns build/icon.iconset -o $APP/Contents/Resources/AppIcon.icns
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.alexmontague.micwarm</string>
  <key>CFBundleName</key><string>MicWarm</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>MicWarm</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>MicWarm keeps your AirPods microphone open so dictation starts instantly. Audio is never recorded or stored.</string>
</dict></plist>
PLIST
codesign --force --sign - $APP
pkill -x MicWarm || true
rm -rf /Applications/MicWarm.app
cp -R $APP /Applications/
echo "Installed /Applications/MicWarm.app"
