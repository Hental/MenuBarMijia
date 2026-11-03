#!/usr/bin/env bash
# Stages the two Windows camera helpers that ship inside the installer:
#   go2rtc.exe        MIT, downloaded from the pinned release and SHA-256 checked
#   ffmpeg-silent.exe minimal LGPL build produced by build-ffmpeg-min.sh
#
# The runtime still downloads go2rtc when this staging step was skipped (for
# example a local `tauri build`), but a shipped installer must include both so
# a fresh offline-ish Windows machine never needs GitHub release assets (#200).
set -euo pipefail

go2rtc_version="1.9.15"
go2rtc_sha256="5b448fc90f15c925406d8da0984301985e385050222c1c2bbdf0a76fe4b1e9cb"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
out_dir="${1:-${repo_root}/windows/src-tauri/camera-bin}"

mkdir -p "${out_dir}"
out_dir="$(cd "${out_dir}" && pwd)"
work_dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/menubarmijia-camera-bin"
if command -v cygpath >/dev/null 2>&1; then
  work_dir="$(cygpath -u "${work_dir}")"
fi
mkdir -p "${work_dir}"

if [[ ! -f "${out_dir}/go2rtc.exe" || "${FORCE:-0}" == "1" ]]; then
  archive="${work_dir}/go2rtc_win64.zip"
  if [[ ! -f "${archive}" ]]; then
    echo "▶ 下载 go2rtc ${go2rtc_version}"
    curl -fL --retry 3 --retry-delay 2 --max-time 300 \
      "https://github.com/AlexxIT/go2rtc/releases/download/v${go2rtc_version}/go2rtc_win64.zip" \
      -o "${archive}"
  fi
  echo "${go2rtc_sha256}  ${archive}" | sha256sum -c -
  rm -rf "${work_dir}/unpacked"
  python -m zipfile -e "${archive}" "${work_dir}/unpacked"
  cp "${work_dir}/unpacked/go2rtc.exe" "${out_dir}/go2rtc.exe"
fi

if [[ ! -f "${out_dir}/GO2RTC-LICENSE.txt" || "${FORCE:-0}" == "1" ]]; then
  curl -fL --retry 3 --retry-delay 2 --max-time 60 \
    "https://raw.githubusercontent.com/AlexxIT/go2rtc/v${go2rtc_version}/LICENSE" \
    -o "${out_dir}/GO2RTC-LICENSE.txt"
fi

bash "${script_dir}/build-ffmpeg-min.sh" "${out_dir}"

echo "✅ Windows 摄像机组件已就绪："
ls -lh "${out_dir}/go2rtc.exe" "${out_dir}/ffmpeg-silent.exe"
