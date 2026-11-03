#!/usr/bin/env bash
# check_release.sh 附件集合的自测（#170）：两端 SBOM 加入严格清单后，
# draft-assets 必须拒绝缺项、多项、坏 SBOM 与校验和不符的安装包。
#
# 只覆盖 draft-assets；assets 还要求离线 Ed25519 签名，CI 没有私钥，
# 那部分仍由 finalize.yml 在真实草稿上验证。
set -euo pipefail
cd "$(dirname "$0")/.."

version="$(tr -d '[:space:]' < VERSION)"
workdir="$(mktemp -d "${TMPDIR:-/tmp}/menubarmijia-release-test.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT

failures=0
pass() { printf 'PASS %s\n' "$1"; }

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

write_checksum() {
    printf '%s  %s\n' "$(sha256_file "$1")" "$(basename "$1")" > "$1.sha256"
}

spdx_document() {
    # 最小但合法的 SPDX 2.3 JSON：check_release.sh 只要求格式与至少一个组件。
    printf '{"spdxVersion":"SPDX-2.3","dataLicense":"CC0-1.0","SPDXID":"SPDXRef-DOCUMENT","name":"%s","documentNamespace":"https://example.invalid/%s","packages":[{"SPDXID":"SPDXRef-Package","name":"go2rtc","versionInfo":"1.9.9"}]}\n' "$1" "$1"
}

new_assets() {
    local dir="$1" dmg="$2" exe="$3" msi="$4"
    mkdir -p "$dir"
    printf 'dmg bytes\n' > "$dir/$dmg"
    printf 'exe bytes\n' > "$dir/$exe"
    printf 'msi bytes\n' > "$dir/$msi"
    write_checksum "$dir/$dmg"
    write_checksum "$dir/$exe"
    write_checksum "$dir/$msi"
    spdx_document "MenuBarMijia-${version}-macos" > "$dir/MenuBarMijia-${version}-macos.spdx.json"
    spdx_document "MenuBarMijia-${version}-windows-x64" > "$dir/MenuBarMijia-${version}-windows-x64.spdx.json"
}

dmg="MenuBarMijia-${version}.dmg"
exe="MenuBarMijia-${version}-windows-x64-setup.exe"
msi="MenuBarMijia-${version}-windows-x64.msi"
good="$workdir/good"
new_assets "$good" "$dmg" "$exe" "$msi"

run_draft() {
    bash scripts/check_release.sh draft-assets "$version" "$1" >"$workdir/output.log" 2>&1
}

expect_draft() {
    # $1 = 0 表示应通过，非 0 表示应拒绝；失败时打印脚本输出便于定位。
    local expected="$1" message="$2" actual=0
    run_draft "$good" || actual=1
    if [ "$actual" = "$expected" ]; then
        pass "$message"
    else
        printf 'FAIL %s\n' "$message"
        sed 's/^/    /' "$workdir/output.log"
        failures=$((failures + 1))
    fi
}

expect_draft 0 'draft-assets accepts the six build files plus both SPDX SBOMs'

rm "$good/MenuBarMijia-${version}-macos.spdx.json"
expect_draft 1 'draft-assets rejects a missing macOS SBOM'
spdx_document "MenuBarMijia-${version}-macos" > "$good/MenuBarMijia-${version}-macos.spdx.json"

rm "$good/MenuBarMijia-${version}-windows-x64.spdx.json"
expect_draft 1 'draft-assets rejects a missing Windows SBOM'
spdx_document "MenuBarMijia-${version}-windows-x64" > "$good/MenuBarMijia-${version}-windows-x64.spdx.json"

printf 'unexpected\n' > "$good/notes.txt"
expect_draft 1 'draft-assets rejects an unexpected extra file'
rm "$good/notes.txt"

printf 'not json\n' > "$good/MenuBarMijia-${version}-macos.spdx.json"
expect_draft 1 'draft-assets rejects an SBOM that is not JSON'
spdx_document "MenuBarMijia-${version}-macos" > "$good/MenuBarMijia-${version}-macos.spdx.json"

printf '{"spdxVersion":"SPDX-2.3","packages":[]}\n' > "$good/MenuBarMijia-${version}-windows-x64.spdx.json"
expect_draft 1 'draft-assets rejects an SBOM with no components'
spdx_document "MenuBarMijia-${version}-windows-x64" > "$good/MenuBarMijia-${version}-windows-x64.spdx.json"

printf 'tampered\n' > "$good/$dmg"
expect_draft 1 'draft-assets rejects an installer whose SHA-256 does not match'

if [ "$failures" -ne 0 ]; then
    printf '❌ %d 项发布附件校验自测失败\n' "$failures" >&2
    exit 1
fi
printf '✅ 发布附件校验自测通过\n'
