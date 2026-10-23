#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"

sdk="${MACOS_SDK:-}"
if [[ -z "$sdk" ]]; then
  if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk ]] &&
     [[ "$(xcode-select -p)" == "/Library/Developer/CommandLineTools" ]]; then
    sdk="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
  else
    sdk="$(xcrun --sdk macosx --show-sdk-path)"
  fi
fi

build_dir="$project_dir/.build-local"
app_dir="$project_dir/dist/v5xs.app"
mkdir -p "$build_dir/modules" "$app_dir/Contents/MacOS" "$app_dir/Contents/Frameworks" \
  "$app_dir/Contents/Resources/Animals"

swiftc -swift-version 6 -sdk "$sdk" -module-cache-path "$build_dir/modules" \
  -emit-library -emit-module -enable-testing -module-name MonitorCore \
  Sources/MonitorCore/*.swift \
  -emit-module-path "$build_dir/MonitorCore.swiftmodule" \
  -o "$build_dir/libMonitorCore.dylib"

swiftc -swift-version 6 -sdk "$sdk" -module-cache-path "$build_dir/modules" \
  -I "$build_dir" -L "$build_dir" -lMonitorCore \
  -framework AppKit -framework SwiftUI -framework Charts \
  -framework ServiceManagement -framework IOKit -framework CoreBluetooth \
  Sources/OrbitMonitor/*.swift -o "$build_dir/v5xs"

cp "$build_dir/v5xs" "$app_dir/Contents/MacOS/v5xs"
cp "$build_dir/libMonitorCore.dylib" "$app_dir/Contents/Frameworks/libMonitorCore.dylib"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "$project_dir/Resources/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
cp "$project_dir"/Resources/Animals/*.png "$app_dir/Contents/Resources/Animals/"
install_name_tool -change "$build_dir/libMonitorCore.dylib" \
  "@executable_path/../Frameworks/libMonitorCore.dylib" "$app_dir/Contents/MacOS/v5xs"
install_name_tool -change ".build-local/libMonitorCore.dylib" \
  "@executable_path/../Frameworks/libMonitorCore.dylib" "$app_dir/Contents/MacOS/v5xs"
codesign --force --deep --sign - "$app_dir" >/dev/null

echo "Built $app_dir"
