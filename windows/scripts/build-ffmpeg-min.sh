#!/usr/bin/env bash
# Builds the minimal LGPL ffmpeg helper bundled with the Windows installer.
#
# go2rtc's `ffmpeg:` source needs an H.264/HEVC decoder and the native MJPEG
# encoder; a full ffmpeg build is 175 MB, while this selection is ~4 MB. The
# output is renamed `ffmpeg-silent.exe` after its PE subsystem is switched to
# GUI, because go2rtc launches it without CREATE_NO_WINDOW (#200 follow-up).
set -euo pipefail

ffmpeg_version="7.1.2"
ffmpeg_sha256="089bc60fb59d6aecc5d994ff530fd0dcb3ee39aa55867849a2bbc4e555f9c304"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
out_dir="${1:-${repo_root}/windows/src-tauri/camera-bin}"
mkdir -p "${out_dir}"
out_dir="$(cd "${out_dir}" && pwd)"

case "$(uname -s)" in
  MINGW*|MSYS*) ;;
  *)
    echo "build-ffmpeg-min.sh targets Windows helpers; run it in MSYS2/Git Bash on Windows." >&2
    exit 1
    ;;
esac

if [[ -f "${out_dir}/ffmpeg-silent.exe" && "${FORCE:-0}" != "1" ]]; then
  echo "▶ 已存在 ${out_dir}/ffmpeg-silent.exe，跳过编译（FORCE=1 可强制重建）"
  exit 0
fi

work_dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/ffmpeg-min-${ffmpeg_version}"
mkdir -p "${work_dir}" "${out_dir}"

archive="${work_dir}/ffmpeg-${ffmpeg_version}.tar.xz"
if [[ ! -f "${archive}" ]]; then
  echo "▶ 下载 FFmpeg ${ffmpeg_version} 源码"
  curl -fL --retry 3 --retry-delay 2 --max-time 300 \
    "https://ffmpeg.org/releases/ffmpeg-${ffmpeg_version}.tar.xz" \
    -o "${archive}"
fi
echo "${ffmpeg_sha256}  ${archive}" | sha256sum -c -

source_dir="${work_dir}/src"
rm -rf "${source_dir}"
mkdir -p "${source_dir}"
tar -xf "${archive}" -C "${source_dir}" --strip-components=1

echo "▶ 配置最小 LGPL 构建"
(
  cd "${source_dir}"
  # Only the RTSP/HLS demuxers, H.264/HEVC/MJPEG decoders, native MJPEG encoder,
  # HTTPS through Windows SChannel, and the small filter set go2rtc uses.
  # No libx264 (GPL) and no external libraries.
  ./configure \
    --arch=x86_64 \
    --target-os=mingw32 \
    --disable-everything \
    --disable-doc \
    --disable-debug \
    --disable-autodetect \
    --enable-ffmpeg \
    --disable-ffplay \
    --disable-ffprobe \
    --enable-protocol=file,pipe,tcp,udp,rtp,http,https,tls,httpproxy,crypto \
    --enable-demuxer=rtsp,sdp,h264,hevc,mjpeg,rawvideo,hls \
    --enable-muxer=mjpeg,rawvideo \
    --enable-decoder=h264,hevc,mjpeg \
    --enable-encoder=mjpeg \
    --enable-parser=h264,hevc,mjpeg \
    --enable-bsf=h264_mp4toannexb,hevc_mp4toannexb \
    --enable-filter=scale,format,null,anull,copy \
    --enable-swscale \
    --enable-avfilter \
    --enable-schannel \
    --enable-small
  echo "▶ 编译 ffmpeg.exe"
  make -j"$(nproc)"
  python "${script_dir}/patch_pe_subsystem.py" ffmpeg.exe "${out_dir}/ffmpeg-silent.exe"
)

echo "✅ 已生成 ${out_dir}/ffmpeg-silent.exe ($(du -h "${out_dir}/ffmpeg-silent.exe" | cut -f1))"
