#!/bin/bash
#
# make-update-manifest.sh — 生成 v5xs 应用内更新清单（默认 dist/update.json）
#
# 数据来源：
#   * dist/v5xs.app/Contents/Info.plist -> version / build / minimumSystemVersion
#   * dist/*.dmg（或 --dmg 指定的文件） -> size / sha256 / architecture
#
# 只依赖 macOS 自带工具（PlistBuddy/plutil、shasum、stat、date、sort、mktemp），
# 不联网、不依赖 jq / python / uv，兼容 macOS 自带的 bash 3.2。
#
# 环境变量：V5XS_UPDATE_URL_BASE 可代替 --url-base 指定下载前缀；
#          V5XS_UPDATE_REPO 指定 GitHub repo（默认 zyw/v5xs）。
#
# 用法：见 --help

set -euo pipefail

# 控制字符（bash 3.2 下用 ANSI-C 引用定义，供 json_escape 使用）
TAB=$'\t'
CR=$'\r'
LF=$'\n'
BS=$'\b'
FF=$'\f'

PROG_NAME="$(basename "$0")"
INVOKE_DIR="$(pwd)"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# 清单中 DMG 下载地址的前缀（最终 url = <prefix>/<dmg 文件名>）。
# 默认按发布 tag（v<version>）指向 GitHub Releases 的不可变下载地址，与客户端所拉的
# update.json 附件（releases/latest/download/update.json，见 Info.plist V5XSUpdateFeedURL）
# 相互独立；可用 --url-base 覆盖，或用 V5XS_UPDATE_URL_BASE 环境变量。
#
DEFAULT_REPO="${V5XS_UPDATE_REPO:-zyw/v5xs}"
DEFAULT_URL_BASE=""   # 解析出版本后按 tag 构造；无法构成 tag 时回退到 latest/download

app_dir="$PROJECT_DIR/dist/v5xs.app"
dmg_dir="$PROJECT_DIR/dist"
out_path="$PROJECT_DIR/dist/update.json"
url_base="$DEFAULT_URL_BASE"
notes_file=""
version_override=""
build_override=""
architecture_override=""
published_at_override=""
min_system_override=""
dmg_args=""   # 换行分隔的 --dmg 参数列表（bash 3.2 无关联数组）

usage() {
  cat <<'EOF'
用法: make-update-manifest.sh [选项]

从 dist/v5xs.app 的 Info.plist 读取版本号，为每个 DMG 计算 sha256 与字节数，
生成客户端自动更新所消费的 JSON 清单（默认 dist/update.json）。

选项:
  --dmg <path>            指定 DMG 文件，可重复（默认自动使用 dist/*.dmg）
  --url-base <prefix>     DMG 下载地址前缀，最终 url = <prefix>/<dmg 文件名>
                          （默认 https://github.com/zyw/v5xs/releases/download/v<version>）
  --notes <file>          发布说明（Markdown）；传 "-" 表示从标准输入读取
  --out <path>            清单输出路径（默认 dist/update.json）
  --app <path>            指定 .app 路径（默认 dist/v5xs.app）
  --dmg-dir <path>        自动发现 DMG 的目录（默认 dist）
  --version <x.y.z>       覆盖清单中的 version（默认取自 Info.plist）
  --build <int>           覆盖清单中的 build（默认取自 Info.plist）
  --minimum-system <ver>  覆盖 minimumSystemVersion（默认取自 LSMinimumSystemVersion）
  --architecture <arch>   覆盖 architecture（arm64 / x86_64 / universal）
  --published-at <time>   覆盖发布时间，RFC3339 UTC（默认当前时间）
  -h, --help              显示本帮助并退出

清单格式:
  {
    "version": "0.2.0",
    "build": 2,
    "minimumSystemVersion": "14.0",
    "publishedAt": "2026-10-25T10:00:00Z",
    "notes": "release notes markdown",
    "downloads": [
      {
        "architecture": "arm64",
        "url": "https://example/v5xs-0.2.0-macOS-26.4-arm64.dmg",
        "size": 12345678,
        "sha256": "hex64"
      }
    ]
  }

architecture 推断规则（按顺序）:
  DMG 文件名含 universal -> universal
  DMG 文件名含 arm64 / aarch64 -> arm64
  DMG 文件名含 x86_64 / amd64 / intel / x64 -> x86_64
  文件名无提示 -> 回退到 `uname -m`（arm64 / x86_64，其它 -> universal）

示例:
  # 生成清单（DMG 自动从 dist/ 发现，URL 指向 GitHub 最新 Release）
  bash scripts/make-update-manifest.sh

  # 指定 DMG、下载前缀与发布说明
  bash scripts/make-update-manifest.sh \
    --dmg dist/v5xs-0.2.0-macOS-26.4-arm64.dmg \
    --url-base https://github.com/zyw/v5xs/releases/download/v0.2.0 \
    --notes docs/release-notes/0.2.0.md

  # 从标准输入读取发布说明，输出到临时路径
  echo "修复若干问题" | bash scripts/make-update-manifest.sh --notes - --out /tmp/update.json

退出码: 0 成功；1 运行时错误（文件缺失、plist 字段非法等）；2 参数错误。
EOF
}

die() {
  printf '%s: 错误: %s\n' "$PROG_NAME" "$1" >&2
  exit 1
}

usage_error() {
  printf '%s: %s\n' "$PROG_NAME" "$1" >&2
  printf '运行 "%s --help" 查看用法。\n' "$PROG_NAME" >&2
  exit 2
}

# 把相对路径按调用者所在目录解析（脚本自身会 cd 到项目根）
resolve_path() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    *)  printf '%s/%s' "$INVOKE_DIR" "$1" ;;
  esac
}

# JSON 字符串转义：反斜杠、双引号、制表/回车/换行等控制字符
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//${TAB}/\\t}"
  s="${s//${CR}/\\r}"
  s="${s//${LF}/\\n}"
  s="${s//${BS}/\\b}"
  s="${s//${FF}/\\f}"
  printf '%s' "$s"
}

# ---------------------------------------------------------------- 参数解析
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dmg)
      [[ $# -ge 2 ]] || usage_error "--dmg 需要一个参数"
      if [[ -n "$dmg_args" ]]; then dmg_args="$dmg_args
$2"; else dmg_args="$2"; fi
      shift 2
      ;;
    --url-base)
      [[ $# -ge 2 ]] || usage_error "--url-base 需要一个参数"
      url_base="$2"; shift 2
      ;;
    --notes)
      [[ $# -ge 2 ]] || usage_error "--notes 需要一个参数"
      notes_file="$2"; shift 2
      ;;
    --out)
      [[ $# -ge 2 ]] || usage_error "--out 需要一个参数"
      out_path="$2"; shift 2
      ;;
    --app)
      [[ $# -ge 2 ]] || usage_error "--app 需要一个参数"
      app_dir="$2"; shift 2
      ;;
    --dmg-dir)
      [[ $# -ge 2 ]] || usage_error "--dmg-dir 需要一个参数"
      dmg_dir="$2"; shift 2
      ;;
    --version)
      [[ $# -ge 2 ]] || usage_error "--version 需要一个参数"
      version_override="$2"; shift 2
      ;;
    --build)
      [[ $# -ge 2 ]] || usage_error "--build 需要一个参数"
      build_override="$2"; shift 2
      ;;
    --minimum-system)
      [[ $# -ge 2 ]] || usage_error "--minimum-system 需要一个参数"
      min_system_override="$2"; shift 2
      ;;
    --architecture)
      [[ $# -ge 2 ]] || usage_error "--architecture 需要一个参数"
      architecture_override="$2"; shift 2
      ;;
    --published-at)
      [[ $# -ge 2 ]] || usage_error "--published-at 需要一个参数"
      published_at_override="$2"; shift 2
      ;;
    -h|--help)
      usage; exit 0
      ;;
    *)
      usage_error "未知参数: $1"
      ;;
  esac
done

# ---------------------------------------------------------------- 版本信息
plist="$app_dir/Contents/Info.plist"
[[ -f "$plist" ]] || die "找不到 Info.plist: $plist（先运行 scripts/build-app.sh）"

# 优先 PlistBuddy（系统自带），失败时回退到 plutil（兼容二进制 plist / 字段缺失）
plist_print() {
  local key="$1" value=""
  value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true)"
  if [[ -z "$value" ]]; then
    value="$(plutil -extract "$key" raw -o - "$plist" 2>/dev/null || true)"
  fi
  printf '%s' "$value"
}

if [[ -n "$version_override" ]]; then
  version="$version_override"
else
  version="$(plist_print CFBundleShortVersionString)"
  [[ -n "$version" ]] || die "$plist 缺少 CFBundleShortVersionString"
fi
[[ "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]] || die "version 非法: '$version'（应形如 0.2.0）"

# 未显式指定下载前缀时，按发布 tag 指向 Releases 的不可变下载地址。
if [[ -z "$url_base" ]]; then
  url_base="https://github.com/$DEFAULT_REPO/releases/download/v${version}"
fi

if [[ -n "$build_override" ]]; then
  build="$build_override"
else
  build="$(plist_print CFBundleVersion)"
  [[ -n "$build" ]] || die "$plist 缺少 CFBundleVersion"
fi
# CFBundleVersion 必须是单调递增的整数，客户端靠它判断是否有新版本
[[ "$build" =~ ^[0-9]+$ ]] || die "build 必须是整数: '$build'（CFBundleVersion 只允许数字）"
[[ "$build" -ge 1 ]] || die "build 必须 >= 1: '$build'"

# 常见坑：改了 Resources/Info.plist 却忘了重新 build-app.sh，
# 清单会沿用 dist/v5xs.app 里的旧版本号。这里做一次非致命提示。
source_plist="$PROJECT_DIR/Resources/Info.plist"
if [[ -z "$version_override" && -z "$build_override" && -f "$source_plist" ]]; then
  source_version="$(plutil -extract CFBundleShortVersionString raw -o - "$source_plist" 2>/dev/null || true)"
  source_build="$(plutil -extract CFBundleVersion raw -o - "$source_plist" 2>/dev/null || true)"
  if [[ -n "$source_version" && "$source_version" != "$version" ]] ||
     [[ -n "$source_build" && "$source_build" != "$build" ]]; then
    printf '%s: 警告: Resources/Info.plist (%s build %s) 与已构建的 dist/v5xs.app (%s build %s) 不一致，请先运行 scripts/build-app.sh\n' \
      "$PROG_NAME" "${source_version:-?}" "${source_build:-?}" "$version" "$build" >&2
  fi
fi

if [[ -n "$min_system_override" ]]; then
  min_system="$min_system_override"
else
  min_system="$(plist_print LSMinimumSystemVersion)"
  [[ -n "$min_system" ]] || min_system="14.0"
fi

if [[ -n "$published_at_override" ]]; then
  published_at="$published_at_override"
else
  published_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
fi
[[ "$published_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
  || die "publishedAt 必须是 RFC3339 UTC 时间（形如 2026-10-25T10:00:00Z）: '$published_at'"

# ---------------------------------------------------------------- 发布说明
notes=""
if [[ -n "$notes_file" ]]; then
  if [[ "$notes_file" == "-" ]]; then
    notes="$(cat)"
  else
    notes_path="$(resolve_path "$notes_file")"
    [[ -f "$notes_path" ]] || die "找不到发布说明文件: $notes_path"
    notes="$(cat "$notes_path")"
  fi
fi

# ---------------------------------------------------------------- DMG 列表
dmg_list=""
if [[ -n "$dmg_args" ]]; then
  dmg_list="$dmg_args"
else
  for candidate in "$dmg_dir"/*.dmg; do
    [[ -e "$candidate" ]] || continue
    if [[ -n "$dmg_list" ]]; then dmg_list="$dmg_list
$candidate"; else dmg_list="$candidate"; fi
  done
  [[ -n "$dmg_list" ]] || die "在 $dmg_dir 下没有找到任何 .dmg（先运行 scripts/build-dmg.sh，或用 --dmg 指定）"
fi

# 排序保证输出稳定
dmg_sorted="$(printf '%s\n' "$dmg_list" | sed '/^[[:space:]]*$/d' | sort)"
[[ -n "$dmg_sorted" ]] || die "没有可用的 DMG"

infer_arch() {
  local name
  name="$(basename "$1")"
  case "$name" in
    *universal*|*Universal*|*UNIVERSAL*) printf 'universal' ;;
    *arm64*|*ARM64*|*aarch64*)          printf 'arm64' ;;
    *x86_64*|*amd64*|*intel*|*Intel*|*x64*) printf 'x86_64' ;;
    *)
      case "$(uname -m)" in
        arm64)  printf 'arm64' ;;
        x86_64) printf 'x86_64' ;;
        *)      printf 'universal' ;;
      esac
      ;;
  esac
}

# ---------------------------------------------------------------- 输出路径
out_path="$(resolve_path "$out_path")"
out_dir="$(dirname "$out_path")"
[[ -d "$out_dir" ]] || mkdir -p "$out_dir"

tmp_path="$(mktemp "${out_path}.XXXXXX")"
cleanup() { rm -f "$tmp_path"; }
trap cleanup EXIT

# ---------------------------------------------------------------- 生成清单
count=0
first=1
arch_seen=""

{
  printf '{\n'
  printf '  "version": "%s",\n' "$(json_escape "$version")"
  printf '  "build": %s,\n' "$build"
  printf '  "minimumSystemVersion": "%s",\n' "$(json_escape "$min_system")"
  printf '  "publishedAt": "%s",\n' "$(json_escape "$published_at")"
  printf '  "notes": "%s",\n' "$(json_escape "$notes")"
  printf '  "downloads": ['

  while IFS= read -r dmg; do
    [[ -n "$dmg" ]] || continue
    dmg_path="$(resolve_path "$dmg")"
    [[ -f "$dmg_path" ]] || die "找不到 DMG: $dmg_path"

    size="$(stat -f%z "$dmg_path")"
    [[ "$size" =~ ^[0-9]+$ ]] || die "无法读取文件大小: $dmg_path"
    sha_line="$(shasum -a 256 "$dmg_path")"
    sha256="${sha_line%% *}"
    [[ "$sha256" =~ ^[0-9a-f]{64}$ ]] || die "sha256 计算异常: $dmg_path"

    if [[ -n "$architecture_override" ]]; then
      arch="$architecture_override"
    else
      arch="$(infer_arch "$dmg_path")"
    fi
    case "$arch" in
      arm64|x86_64|universal) ;;
      *) die "architecture 非法: '$arch'（只允许 arm64 / x86_64 / universal）" ;;
    esac

    case "
$arch_seen
" in
      *"
$arch
"*) printf '%s: 警告: architecture "%s" 重复，客户端可能无法区分这两个 DMG\n' "$PROG_NAME" "$arch" >&2 ;;
      *) arch_seen="${arch_seen:+${arch_seen}
}$arch" ;;
    esac

    dmg_name="$(basename "$dmg_path")"
    url="${url_base%/}/$dmg_name"

    if [[ $first -eq 1 ]]; then first=0; else printf ','; fi
    printf '\n    {\n'
    printf '      "architecture": "%s",\n' "$(json_escape "$arch")"
    printf '      "url": "%s",\n' "$(json_escape "$url")"
    printf '      "size": %s,\n' "$size"
    printf '      "sha256": "%s"\n' "$sha256"
    printf '    }'
    count=$((count + 1))
  done <<< "$dmg_sorted"

  if [[ $count -gt 0 ]]; then printf '\n  '; fi
  printf ']\n'
  printf '}\n'
} > "$tmp_path"

# 自检：plutil 能把合法 JSON 当 plist 解析（-lint 只认 XML/二进制格式，故用 -p）
if command -v plutil >/dev/null 2>&1; then
  plutil -p "$tmp_path" >/dev/null 2>&1 || die "生成的 JSON 未通过 plutil 解析校验: $tmp_path"
fi

mv -f "$tmp_path" "$out_path"
trap - EXIT

printf 'Wrote %s\n' "$out_path"
printf '  version: %s (build %s)\n' "$version" "$build"
printf '  downloads: %s\n' "$count"
printf '  feed:  https://github.com/%s/releases/latest/download/update.json\n' "$DEFAULT_REPO"
