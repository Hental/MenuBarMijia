#!/usr/bin/env python3
"""Rewrite the PE optional-header subsystem to GUI (2).

go2rtc is started with CREATE_NO_WINDOW, but it launches ffmpeg with Go's default
process attributes. A console-subsystem ffmpeg would therefore allocate a visible
console window. The GUI subsystem keeps inherited stdio pipes working (go2rtc reads
MJPEG from ffmpeg's stdout) and never opens a console.

Usage: patch_pe_subsystem.py <ffmpeg.exe> <ffmpeg-silent.exe>
"""

from __future__ import annotations

import struct
import sys

GUI_SUBSYSTEM = 2
PE32 = 0x10B
PE32_PLUS = 0x20B


def patch(source: str, destination: str) -> None:
    data = bytearray(open(source, "rb").read())
    if data[:2] != b"MZ":
        raise SystemExit(f"{source}: not a PE file (missing MZ header)")
    pe_offset = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe_offset : pe_offset + 4] != b"PE\0\0":
        raise SystemExit(f"{source}: not a PE file (missing PE signature)")
    optional_header = pe_offset + 24
    magic = struct.unpack_from("<H", data, optional_header)[0]
    if magic not in (PE32, PE32_PLUS):
        raise SystemExit(f"{source}: unsupported PE optional-header magic {magic:#x}")
    struct.pack_into("<H", data, optional_header + 68, GUI_SUBSYSTEM)
    with open(destination, "wb") as handle:
        handle.write(data)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__.strip())
    patch(sys.argv[1], sys.argv[2])
