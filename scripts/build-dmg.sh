#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_dir="$project_dir/dist/v5xs.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_dir/Contents/Info.plist")"
os_name="macOS"
os_version="$(sw_vers -productVersion)"
architecture="$(uname -m)"
output="$project_dir/dist/v5xs-$version-$os_name-$os_version-$architecture.dmg"
workdir="$(mktemp -d /private/tmp/v5xs-dmg.XXXXXX)"
trap 'rm -rf "$workdir"' EXIT

codesign --verify --deep --strict "$app_dir"
export UV_CACHE_DIR="$project_dir/.build-local/uv-cache"
export UV_TOOL_DIR="$project_dir/.build-local/uv-tools"
export V5XS_PROJECT_DIR="$project_dir"
uv tool run --from dmgbuild dmgbuild -s "$project_dir/scripts/dmg-settings.py" \
  v5xs "$workdir/v5xs.dmg"
hdiutil verify "$workdir/v5xs.dmg" -quiet
mv -f "$workdir/v5xs.dmg" "$output"
echo "Built $output"
