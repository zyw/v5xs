#!/bin/bash
# 打包静态官网（website/）为可部署的静态站点。
#
# 产物：
#   website/dist/                     可直接部署的静态站点目录（对应 website/.openai/hosting.json 的 static.directory）
#   dist/v5xs-website-<version>.zip   同一份内容的压缩包，便于上传/分发
#
# 官网没有任何构建步骤（纯 HTML/CSS/JS，无 CDN、无外部字体），
# 这里的“打包”= 清理 → 拷贝运行时文件 → 自检引用完整 → 压缩。
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"

site_src="$project_dir/website"
site_out="$site_src/dist"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_dir/Resources/Info.plist")"
archive="$project_dir/dist/v5xs-website-$version.zip"

if [[ ! -f "$site_src/index.html" ]]; then
  echo "错误: 缺少 $site_src/index.html" >&2
  exit 1
fi

echo "打包 website（版本 ${version}）"
rm -rf "$site_out"
mkdir -p "$site_out/en" "$site_out/assets" "$project_dir/dist"

# 只拷贝运行时需要的文件：.openai/ 是托管平台配置，.DS_Store 是 macOS 垃圾文件，都不应上线。
cp "$site_src/index.html" "$site_src/style.css" "$site_src/script.js" "$site_out/"
cp "$site_src/en/index.html" "$site_out/en/index.html"
cp "$site_src"/assets/*.png "$site_out/assets/"

# 自检：HTML 里引用的站内资源必须真实存在，避免上线后 404。
# 关键点：相对引用要按「页面自身所在目录」解析，而不是一律按站点根拼路径
# （en/index.html 用的是 ../assets/...，按根拼会得到错误的命中结果）。
missing=0
for page in index.html en/index.html; do
  page_dir="${page%%index.html}"          # "" 或 "en/"
  while IFS= read -r ref; do
    case "$ref" in
      http://*|https://*|"#"*|"") continue ;;   # 外链、纯锚点跳过
    esac
    rel="${ref%%#*}"                            # 去掉锚点
    target="$site_out/${page_dir}${rel}"
    if [[ ! -e "$target" ]]; then
      echo "  缺失引用: $page -> $ref" >&2
      missing=1
    fi
  done < <(grep -ho 'src="[^"]*"\|href="[^"]*"' "$site_out/$page" | sed 's/^[a-z]*="//; s/"$//' | sort -u)
done
if [[ "$missing" -ne 0 ]]; then
  echo "错误: 静态站点存在缺失引用，已中止。" >&2
  exit 1
fi

# 压缩：在站点根目录内打包，解压后直接得到 index.html，而不是多一层目录。
rm -f "$archive"
(cd "$site_out" && zip -qr -X "$archive" .)

echo "已生成静态站点: $site_out"
echo "已生成压缩包:   $archive ($(stat -f%z "$archive") bytes)"
