# Windows camera helpers

This folder is the Tauri `bundle.resources` source for the two helpers embedded in
the installer:

- `go2rtc.exe` — MIT, pinned to [go2rtc 1.9.15](https://github.com/AlexxIT/go2rtc/releases/tag/v1.9.15)
- `ffmpeg-silent.exe` — minimal LGPL FFmpeg 7.1.2 build (H.264/HEVC decode → MJPEG)

Both are gitignored. CI builds them with
`windows/scripts/prepare-camera-bin.sh`; run the same script locally before
`npx tauri build` if you want an installer that works without the runtime
download fallback. This README only keeps the glob non-empty so local builds
without the helpers still succeed.
