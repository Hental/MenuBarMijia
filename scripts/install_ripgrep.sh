#!/usr/bin/env bash
# Install a pinned ripgrep release binary when `rg` is not already on PATH.
# CI uses this instead of `brew install` / compiling from source.
set -euo pipefail

if command -v rg >/dev/null 2>&1; then
    exit 0
fi

version="14.1.1"
case "$(uname -s)-$(uname -m)" in
    Linux-x86_64)
        asset="ripgrep-${version}-x86_64-unknown-linux-musl.tar.gz"
        sha="4cf9f2741e6c465ffdb7c26f38056a59e2a2544b51f7cc128ef28337eeae4d8e"
        ;;
    Darwin-arm64)
        asset="ripgrep-${version}-aarch64-apple-darwin.tar.gz"
        sha="24ad76777745fbff131c8fbc466742b011f925bfa4fffa2ded6def23b5b937be"
        ;;
    *)
        echo "❌ 没有 $(uname -s)-$(uname -m) 的预编译 ripgrep ${version}" >&2
        exit 1
        ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
url="https://github.com/BurntSushi/ripgrep/releases/download/${version}/${asset}"
curl -fsSL --retry 2 --max-time 60 "$url" -o "$tmp/rg.tar.gz"
if command -v sha256sum >/dev/null 2>&1; then
    echo "${sha}  $tmp/rg.tar.gz" | sha256sum -c -
else
    echo "${sha}  $tmp/rg.tar.gz" | shasum -a 256 -c -
fi
tar -xzf "$tmp/rg.tar.gz" -C "$tmp"
install_dir="${HOME}/.local/bin"
mkdir -p "$install_dir"
cp "$tmp"/ripgrep-*/rg "$install_dir/rg"
chmod +x "$install_dir/rg"
if [ -n "${GITHUB_PATH:-}" ]; then
    echo "$install_dir" >> "$GITHUB_PATH"
fi
export PATH="${install_dir}:${PATH}"
command -v rg >/dev/null 2>&1
echo "✅ ripgrep ${version} -> $(command -v rg)"
