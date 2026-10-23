#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
sdk="${MACOS_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk}"
if [[ ! -d "$sdk" ]]; then sdk="$(xcrun --sdk macosx --show-sdk-path)"; fi
build_dir="$project_dir/.build-local"
mkdir -p "$build_dir/modules"
swiftc -swift-version 6 -sdk "$sdk" -module-cache-path "$build_dir/modules" \
  -emit-library -emit-module -enable-testing -module-name MonitorCore \
  Sources/MonitorCore/*.swift \
  -emit-module-path "$build_dir/MonitorCore.swiftmodule" \
  -o "$build_dir/libMonitorCore.dylib"
swiftc -swift-version 6 -sdk "$sdk" -module-cache-path "$build_dir/modules" \
  -I "$build_dir" -L "$build_dir" -lMonitorCore \
  scripts/test-math.swift -o "$build_dir/test-math"
DYLD_LIBRARY_PATH="$build_dir" "$build_dir/test-math"
