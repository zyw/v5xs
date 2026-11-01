#!/bin/bash
# 构建发版所需的辅助工具（目前是清单签名工具）。
# 这些工具不属于 App 本体，只给发版流程用，所以单独编译到 .build-local/。
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"

sdk="$(bash scripts/sdk-path.sh)"

build_dir="$project_dir/.build-local"
mkdir -p "$build_dir/modules"

# 先确保 MonitorCore 是最新的：签名工具要复用客户端的规范化逻辑，
# 两边不一致会导致「发出去的清单客户端验不过」。
swiftc -swift-version 6 -sdk "$sdk" -module-cache-path "$build_dir/modules" \
  -emit-library -emit-module -enable-testing -module-name MonitorCore \
  Sources/MonitorCore/*.swift \
  -emit-module-path "$build_dir/MonitorCore.swiftmodule" \
  -o "$build_dir/libMonitorCore.dylib"

swiftc -swift-version 6 -sdk "$sdk" -module-cache-path "$build_dir/modules" \
  -I "$build_dir" -L "$build_dir" -lMonitorCore \
  scripts/sign-manifest.swift -o "$build_dir/sign-manifest"

echo "Built $build_dir/sign-manifest"
