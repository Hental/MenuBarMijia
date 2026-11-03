#!/usr/bin/env bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT_DIR"

LINT_ONLY=0
SKIP_SNAPSHOTS=0
for argument in "$@"; do
    case "$argument" in
        --lint-only) LINT_ONLY=1 ;;
        --skip-snapshots) SKIP_SNAPSHOTS=1 ;;
        *)
            echo "❌ 未知参数：${argument}（可用：--lint-only --skip-snapshots）" >&2
            exit 2
            ;;
    esac
done

# The hook lives in the shared git directory, so every worktree gets the same gate.
GIT_COMMON_DIR="$(git rev-parse --git-common-dir 2>/dev/null || true)"
case "$GIT_COMMON_DIR" in
    "") ;;
    /*) ;;
    *) GIT_COMMON_DIR="$ROOT_DIR/$GIT_COMMON_DIR" ;;
esac
if [ -n "$GIT_COMMON_DIR" ] && [ -d "$GIT_COMMON_DIR/hooks" ]; then
    HOOK_PATH="$GIT_COMMON_DIR/hooks/pre-commit"
    HOOK_SOURCE="$ROOT_DIR/scripts/hooks/pre-commit"
    if [ -f "$HOOK_SOURCE" ] && [ "$(readlink "$HOOK_PATH" 2>/dev/null || true)" != "$HOOK_SOURCE" ]; then
        ln -sfn "$HOOK_SOURCE" "$HOOK_PATH" 2>/dev/null || true
    fi
fi

search_matches() {
    local pattern="$1"
    shift
    if command -v rg >/dev/null 2>&1; then
        rg -n "$pattern" "$@"
    else
        grep -rnE "$pattern" "$@"
    fi
}

search_quiet() {
    local pattern="$1"
    shift
    if command -v rg >/dev/null 2>&1; then
        rg -q "$pattern" "$@"
    else
        grep -qE "$pattern" "$@"
    fi
}

search_files() {
    local pattern="$1"
    shift
    if command -v rg >/dev/null 2>&1; then
        rg -l "$pattern" "$@"
    else
        grep -rlE "$pattern" "$@"
    fi
}

echo "🔍 [1/4] 检查是否存在硬编码 JWT / 密钥 / 个人局域网地址泄露..."
if search_matches 'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}' Sources/ Tests/; then
    echo "❌ 检测到疑似 JWT Token，请移除后再提交！"
    exit 1
fi

if ! search_quiet 'defaultSeededToken = ""' Sources/MijiaCore/KeychainAndPrefs.swift; then
    echo "❌ KeychainAndPrefs.swift 中的 defaultSeededToken 必须为空字符串！"
    exit 1
fi

if ! search_quiet 'defaultHost = ""' Sources/MijiaCore/LGWebOSClient.swift; then
    echo "❌ LGWebOSClient.swift 中的 defaultHost 必须为空字符串！"
    exit 1
fi

if search_matches '10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' Sources/ Tests/ || search_matches 'localhost:3425' Sources/; then
    echo "❌ 检测到硬编码的个人局域网 IP 或本机调试端口 (localhost:3425)，请移除！"
    exit 1
fi

echo "🔍 [2/4] 检查机械性编码规范 (kVK_* 键码常量 & UNUserNotificationCenter Bundle 守卫)..."
if search_matches 'event\.keyCode[[:space:]]*==[[:space:]]*[0-9]+' Sources/; then
    echo "❌ 请使用 Carbon 的 kVK_* 常量，不要直接比较 event.keyCode 数字字面量！"
    exit 1
fi

for f in $(search_files 'UNUserNotificationCenter\.current\(\)' Sources || true); do
    if ! search_quiet 'pathExtension == "app"' "$f"; then
        echo "❌ $f 调用了 UNUserNotificationCenter.current()，但缺少 Bundle.main.bundleURL.pathExtension == \"app\" 守卫（会导致 swift test 崩溃）！"
        exit 1
    fi
done

for f in $(search_files '\.glassEffect\(|GlassEffectContainer' Sources || true); do
    # ripgrep prints Windows paths with backslashes; compare in one separator style.
    if [ "${f//\\//}" != "Sources/MenuBarMijiaApp/ThemeAndMotion.swift" ]; then
        echo "❌ $f 直接使用了 macOS 26 专属的 .glassEffect 或 GlassEffectContainer，请改用 ThemeAndMotion.swift 中的 adaptiveGlass / AdaptiveGlassContainer 以保持 macOS 14+ 兼容！"
        exit 1
    fi
done

if command -v rg >/dev/null 2>&1; then
    if rg -nU 'return \([^;{}]*\bawait\b' Sources; then
        echo "❌ 请勿在 return 元组字面量内直接内联 await（Swift 6.4 -O 协程分片优化会消除元组首字段写入导致 EXC_BAD_ACCESS），请先用 let 变量接收 await 结果再构造返回值！"
        exit 1
    fi
elif search_matches 'return \([^)]*\bawait\b' Sources; then
    echo "❌ 请勿在 return 元组字面量内直接内联 await（Swift 6.4 -O 协程分片优化会消除元组首字段写入导致 EXC_BAD_ACCESS），请先用 let 变量接收 await 结果再构造返回值！"
    exit 1
fi

if command -v xmllint >/dev/null 2>&1; then
    xmllint --noout docs/assets/*.svg Resources/AppIcon/*.svg
elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys, xml.etree.ElementTree as ET; [ET.parse(f) for f in sys.argv[1:]]' docs/assets/*.svg Resources/AppIcon/*.svg
fi

if ! cmp -s Resources/AppIcon/AppIcon-Dark.svg docs/assets/logo-dark.svg || ! cmp -s Resources/AppIcon/AppIcon-Light.svg docs/assets/logo-light.svg; then
    echo "❌ docs/assets/logo-{dark,light}.svg 与 Resources/AppIcon/AppIcon-{Dark,Light}.svg 不一致，请运行 swift scripts/generate_app_icon.swift 同步！"
    exit 1
fi

# Design-token and Ed25519 checks need python3. CI runs them on ubuntu-latest
# (the Swift container image does not ship python3).
if command -v python3 >/dev/null 2>&1; then
    python3 scripts/check_design_tokens.py
    python3 - <<'PY'
import base64
import re
import sys

files = {
    "Sources/MijiaCore/UpdateChecker.swift": r'updateSigningPublicKeyBase64\s*=\s*"([^"]+)"',
    "scripts/sign_update.swift": r'expectedPublicKeyBase64\s*=\s*"([^"]+)"',
    "windows/src/core/updateChecker.ts": r'UPDATE_SIGNING_PUBLIC_KEY_BASE64\s*=\s*"([^"]+)"',
    "windows/src-tauri/src/main.rs": r'UPDATE_SIGNING_PUBLIC_KEY_BASE64:\s*&str\s*=\s*"([^"]+)"',
}
keys = {}
for path, pat in files.items():
    with open(path, encoding="utf-8") as f:
        m = re.search(pat, f.read())
    if not m:
        sys.exit(f"❌ 无法从 {path} 读取 Ed25519 更新公钥常量")
    keys[path] = m.group(1)
if len(set(keys.values())) != 1:
    sys.exit(f"❌ 双端 Ed25519 更新公钥不一致：{keys}")

overlap_files = {
    "Sources/MijiaCore/UpdateChecker.swift": r'updateSigningOverlapPublicKeyBase64\s*=\s*"([^"]*)"',
    "windows/src-tauri/src/main.rs": r'UPDATE_SIGNING_OVERLAP_PUBLIC_KEY_BASE64:\s*&str\s*=\s*"([^"]*)"',
}
overlaps = {}
for path, pat in overlap_files.items():
    with open(path, encoding="utf-8") as f:
        m = re.search(pat, f.read())
    if not m:
        sys.exit(f"❌ 无法从 {path} 读取 Ed25519 过渡公开钥常量")
    overlaps[path] = m.group(1)
if len(set(overlaps.values())) != 1:
    sys.exit(f"❌ 双端 Ed25519 过渡公开钥不一致：{overlaps}")
overlap = next(iter(overlaps.values()))
if overlap:
    try:
        decoded = base64.b64decode(overlap, validate=True)
    except Exception as error:
        sys.exit(f"❌ Ed25519 过渡公开钥不是合法 base64：{error}")
    if len(decoded) != 32:
        sys.exit(f"❌ Ed25519 过渡公开钥长度为 {len(decoded)} 字节，预期 32")
    if overlap in keys.values():
        sys.exit("❌ Ed25519 过渡公开钥不能与当前签名公钥相同")
PY
    python3 scripts/update_manifest.py self-test
    # 发布附件集合（含两端 SBOM）是发版硬门槛，用 fixture 验证严格清单不会悄悄放宽。
    bash scripts/test_check_release.sh
fi

large_files=""
for dir in Sources Tests windows/src windows/src-tauri/src; do
    [ -d "$dir" ] || continue
    while IFS= read -r -d '' file; do
        lines=$(wc -l < "$file" | tr -d '[:space:]')
        if [ "$lines" -gt 1500 ]; then
            large_files="${large_files}  ${lines}  ${file}"$'\n'
        fi
    done < <(find "$dir" -type f \( -name '*.swift' -o -name '*.ts' -o -name '*.rs' \) -print0)
done
if [ -n "$large_files" ]; then
    echo "⚠️  单文件行数告警（> 1500 行；新代码优先拆分，见 #184）："
    printf '%s' "$large_files"
else
    echo "✅ 没有超过 1500 行的源文件。"
fi

if [ "$LINT_ONLY" = "1" ]; then
    echo "✅ 密钥与机械性编码规范检查通过！"
    exit 0
fi

swift_status=0
swift_skipped=0
if [ "$(uname -s)" = "Linux" ]; then
    # Package.swift requires the macOS SDK. CI's linux-core job runs MijiaCore through this
    # shim; `swift test` at the repo root cannot compile Security/AppKit imports on Linux.
    echo "🧪 [3/4] 运行 Linux 上的 MijiaCore 测试（scripts/linux-check）与双端黄金语料校验..."
    bash scripts/linux-check/run.sh || swift_status=$?
elif ! command -v swift >/dev/null 2>&1; then
    # Windows development machines have no Swift toolchain; CI still runs the suite.
    swift_skipped=1
    echo "⏭️  跳过 Swift 门槛：未找到 swift"
elif [ "$SKIP_SNAPSHOTS" = "1" ]; then
    # The local macOS renderer drifts from the CI-recorded baselines on every run, so a local gate
    # that includes SnapshotTests can never pass. CI still records and compares the baselines.
    echo "🧪 [3/4] 运行 Swift 单元测试（跳过快照）与双端黄金语料校验..."
    swift test --skip SnapshotTests || swift_status=$?
else
    echo "🧪 [3/4] 运行 Swift 单元测试 (swift test) 与双端黄金语料校验..."
    swift test || swift_status=$?
fi

echo "🧪 [4/4] 运行 Windows 前端测试与类型检查..."
windows_status=0
if [ -x "windows/node_modules/.bin/tsx" ]; then
    (cd windows && npm test && npm run typecheck) || windows_status=$?
else
    echo "⏭️  跳过 Windows 门槛：未找到 windows/node_modules（先 cd windows && npm ci）"
fi

if [ "$swift_status" -ne 0 ] || [ "$windows_status" -ne 0 ]; then
    echo "❌ 门禁未通过：swift=$swift_status windows=$windows_status" >&2
    exit 1
fi

if [ "$swift_skipped" = "1" ]; then
    echo "✅ Windows 门禁检查与单元测试通过（Swift 未运行：未找到 swift）"
else
    echo "✅ [4/4] 所有门禁检查与单元测试全部通过！"
fi
