#!/bin/bash
# 用仓库内置的 Ed25519 公钥复验 dist/update.json 的签名，确认发版用的私钥
# 与编译进 App 的公钥确实配对（见 .github/workflows/publish-update-feed.yml）。
#
# 前提：已通过 scripts/dev-build-tools.sh 把 MonitorCore 编进 .build-local/。
# 警告：这里必须用与编译 MonitorCore 完全相同的 SDK（走 scripts/sdk-path.sh）加载模块，
#       否则会报 cannot load module ... built with SDK <不同>。
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
manifest="${1:-dist/update.json}"

[[ -f "$manifest" ]] || { echo "错误: 找不到清单 $manifest" >&2; exit 1; }
[[ -f .build-local/MonitorCore.swiftmodule ]] || {
  echo "错误: 缺少 .build-local/MonitorCore.swiftmodule，先运行 scripts/dev-build-tools.sh" >&2; exit 1
}

sdk="$(bash scripts/sdk-path.sh)"
cat > /tmp/verify-update-signature.swift <<'SWIFT'
import Foundation
import MonitorCore

let data = FileManager.default.contents(atPath: CommandLine.arguments[1])!
let release = try UpdateFeed.release(from: data)
if let failure = UpdateSignature.verify(
    release: release,
    signatureBase64: release.signature ?? "",
    publicKeyBase64: UpdateSigningKey.publicKeyBase64
) {
    FileHandle.standardError.write(Data("签名校验失败: \(failure)\n".utf8))
    exit(1)
}
print("签名校验通过：v\(release.version) build \(release.build)")
SWIFT
swiftc -swift-version 6 -sdk "$sdk" -module-cache-path .build-local/modules   -I .build-local -L .build-local -lMonitorCore   /tmp/verify-update-signature.swift -o /tmp/verify-update-signature
DYLD_LIBRARY_PATH=.build-local /tmp/verify-update-signature "$manifest"
