#!/usr/bin/env bash
# Build (unless skipped) and install the app into the bundle the user actually launches.
# The previous bundle is kept next to the backup directory printed at the end, so a bad build is
# one `mv` away from being rolled back.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEFAULT_TARGET="$HOME/Documents/MenuBarMijia-wt/MenuBarMijia.app"
TARGET="${INSTALL_TARGET:-$DEFAULT_TARGET}"
BUNDLE=""
SKIP_BUILD=0
DRY_RUN=0
RELAUNCH=1

usage() {
    cat <<'USAGE'
用法: scripts/install_local_app.sh [选项]

  --skip-build        直接使用 ROOT/MenuBarMijia.app，不重新打包
  --bundle <path>     安装指定的 .app（仍会校验 CFBundleVersion 与 HEAD 一致）
  --target <path>     安装到指定位置（默认 $HOME/Documents/MenuBarMijia-wt/MenuBarMijia.app，
                      也可用 INSTALL_TARGET 环境变量）
  --dry-run           只校验并打印计划，不改动任何文件
  --no-relaunch       不关闭正在运行的实例，也不自动打开
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --skip-build) SKIP_BUILD=1; shift ;;
        --bundle) BUNDLE="${2:?--bundle 需要路径}"; shift 2 ;;
        --target) TARGET="${2:?--target 需要路径}"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --no-relaunch) RELAUNCH=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "未知参数：$1" >&2; usage >&2; exit 2 ;;
    esac
done

fail() { echo "❌ $*" >&2; exit 1; }

if [ "$SKIP_BUILD" = "0" ]; then
    echo "▶ 打包 MenuBarMijia.app..."
    bash "$ROOT/scripts/build_app.sh"
fi
BUNDLE="${BUNDLE:-$ROOT/MenuBarMijia.app}"
[ -d "$BUNDLE" ] || fail "找不到 $BUNDLE"

BUNDLE="$(cd "$BUNDLE" && pwd)"
EXPECTED_BUILD="$(git -C "$ROOT" rev-list --count HEAD)"
ACTUAL_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
[ -n "$ACTUAL_BUILD" ] || fail "$BUNDLE 缺少 CFBundleVersion"
[ "$ACTUAL_BUILD" = "$EXPECTED_BUILD" ] || \
    fail "包内版本 $ACTUAL_BUILD 与 HEAD 的 $EXPECTED_BUILD 不一致，请先重新打包或改用正确的 --bundle"

codesign --verify --deep --strict "$BUNDLE" || fail "打包产物签名校验失败"
BUNDLE_SHA="$(shasum -a 256 "$BUNDLE/Contents/MacOS/MenuBarMijiaApp" | awk '{print $1}')"

echo "▶ 计划安装：$BUNDLE"
echo "  目标位置：$TARGET"
echo "  构建号：$ACTUAL_BUILD"
if [ -d "$TARGET" ]; then
    echo "  现有版本：$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$TARGET/Contents/Info.plist" 2>/dev/null || echo '未知')"
fi

if [ "$DRY_RUN" = "1" ]; then
    echo "✅ 校验通过（--dry-run，未改动文件）"
    exit 0
fi

[ "$BUNDLE" != "$TARGET" ] || fail "--bundle 与 --target 不能是同一个位置"

mkdir -p "$(dirname "$TARGET")"
BACKUP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mmb-previous-app.XXXXXX")"
if [ -d "$TARGET" ]; then
    mv "$TARGET" "$BACKUP_DIR/MenuBarMijia.app"
fi

restore() {
    rm -rf "$TARGET"
    if [ -d "$BACKUP_DIR/MenuBarMijia.app" ]; then
        mv "$BACKUP_DIR/MenuBarMijia.app" "$TARGET"
        echo "↩️ 已恢复原有应用" >&2
    fi
}
trap 'restore' ERR

STAGING="$TARGET.staging.$$"
rm -rf "$STAGING"
ditto "$BUNDLE" "$STAGING"
mv "$STAGING" "$TARGET"
trap - ERR

codesign --verify --deep --strict "$TARGET" || fail "安装后签名校验失败，原应用在 $BACKUP_DIR"
INSTALLED_SHA="$(shasum -a 256 "$TARGET/Contents/MacOS/MenuBarMijiaApp" | awk '{print $1}')"
[ "$INSTALLED_SHA" = "$BUNDLE_SHA" ] || fail "安装后的二进制与打包产物不一致，原应用在 $BACKUP_DIR"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$TARGET/Contents/Info.plist")" = "$EXPECTED_BUILD" ] || \
    fail "安装后的构建号不是 ${EXPECTED_BUILD}，原应用在 $BACKUP_DIR"

if [ "$RELAUNCH" = "1" ]; then
    killall MenuBarMijiaApp 2>/dev/null || true
    sleep 0.5
    open "$TARGET"
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if pgrep -f "$TARGET/Contents/MacOS/MenuBarMijiaApp" >/dev/null 2>&1; then break; fi
        sleep 0.3
    done
    pgrep -fl MenuBarMijiaApp | head -3 || fail "已安装但应用没有启动：$TARGET"
fi

echo "✅ 已安装 ${TARGET}（构建号 ${ACTUAL_BUILD}）"
echo "   上一版本保留在：$BACKUP_DIR/MenuBarMijia.app"
