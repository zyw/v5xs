#!/bin/bash
# 打印当前构建使用的 macOS SDK 路径。
#
# 所有需要编译 Swift（或加载 .build-local 里已编译模块）的脚本，
# 都必须从这里取 SDK，避免同一套构建产物被不同脚本用不同 SDK 编译/加载。
# 典型事故：CI 上通过 xcrun 得到 macosx26.5 编译了 MonitorCore.swiftmodule，
# 校验步骤却硬编码用 macosx15.4 去加载它 → "cannot load module ... built with SDK ..."。
set -euo pipefail

if [[ -n "${MACOS_SDK:-}" ]]; then
  printf '%s\n' "$MACOS_SDK"
  exit 0
fi

# Command Line Tools 场景下优先用与 App 目标匹配的 15.4 SDK（仓库既有约定）。
# 注意：此分支要求 xcode-select 确实指向 Command Line Tools；
# 若用的是完整 Xcode（如 CI 的 macOS runner），走 xcrun 取默认 SDK。
if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk ]] &&
   [[ "$(xcode-select -p)" == "/Library/Developer/CommandLineTools" ]]; then
  printf '%s\n' "/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
else
  xcrun --sdk macosx --show-sdk-path
fi
