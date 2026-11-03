#!/usr/bin/env python3

import argparse
import hashlib
import json
import pathlib
import re
import sys
import tempfile

VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
KEY_RE = re.compile(r'updateSigningPublicKeyBase64\s*=\s*"([^"]+)"')
ROOT = pathlib.Path(__file__).resolve().parents[1]
PUBLIC_KEY_SOURCE = ROOT / "Sources/MijiaCore/UpdateChecker.swift"
GOLDEN = ROOT / "scripts/testdata/MenuBarMijia-1.1.7.update.json"


def public_key() -> str:
    match = KEY_RE.search(PUBLIC_KEY_SOURCE.read_text(encoding="utf-8"))
    if not match:
        raise SystemExit(f"无法从 {PUBLIC_KEY_SOURCE} 读取 updateSigningPublicKeyBase64")
    return match.group(1)


def version_key(text: str) -> tuple[int, int, int]:
    major, minor, patch = text.split(".")
    return int(major), int(minor), int(patch)


def canonical_bytes(version: str, min_from: str, key_id: str, digests: tuple[str, str, str]) -> bytes:
    if not VERSION_RE.fullmatch(version) or not VERSION_RE.fullmatch(min_from):
        raise SystemExit("版本必须是 x.y.z")
    if version_key(min_from) > version_key(version):
        raise SystemExit("min_from 不能高于 version")
    for digest in digests:
        if not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise SystemExit("SHA-256 必须是 64 位小写十六进制")
    document = {
        "version": version,
        "min_from": min_from,
        "key_id": key_id,
        "files": [
            {"platform": "macos", "file": f"MenuBarMijia-{version}.dmg", "sha256": digests[0]},
            {
                "platform": "windows",
                "file": f"MenuBarMijia-{version}-windows-x64-setup.exe",
                "sha256": digests[1],
            },
            {"platform": "windows", "file": f"MenuBarMijia-{version}-windows-x64.msi", "sha256": digests[2]},
        ],
    }
    return (json.dumps(document, separators=(",", ":"), ensure_ascii=False) + "\n").encode("utf-8")


def package_names(version: str) -> tuple[str, str, str]:
    return (
        f"MenuBarMijia-{version}.dmg",
        f"MenuBarMijia-{version}-windows-x64-setup.exe",
        f"MenuBarMijia-{version}-windows-x64.msi",
    )


def version_from_dmg(path: pathlib.Path) -> str:
    name = path.name
    prefix = "MenuBarMijia-"
    suffix = ".dmg"
    if not (name.startswith(prefix) and name.endswith(suffix)):
        raise SystemExit("DMG 文件名必须是 MenuBarMijia-<version>.dmg")
    version = name[len(prefix) : -len(suffix)]
    if not VERSION_RE.fullmatch(version):
        raise SystemExit(f"DMG 版本不是 x.y.z：{version}")
    return version


def file_sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_sidecar(package: pathlib.Path) -> str:
    sidecar = pathlib.Path(str(package) + ".sha256")
    if not sidecar.is_file() or sidecar.stat().st_size == 0:
        raise SystemExit(f"校验文件缺失或为空：{sidecar.name}")
    parts = sidecar.read_text(encoding="utf-8").split()
    if len(parts) < 2:
        raise SystemExit(f"无法解析校验文件：{sidecar.name}")
    digest = parts[0].lower()
    name = parts[1].lstrip("*")
    if not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise SystemExit(f"校验文件中的 SHA-256 格式错误：{sidecar.name}")
    if name != package.name:
        raise SystemExit(f"{sidecar.name} 指向 {name}，预期 {package.name}")
    actual = file_sha256(package)
    if digest != actual:
        raise SystemExit(f"SHA-256 不匹配：{package.name}（期望 {digest}，实际 {actual}）")
    return actual


def encode(min_from: str, dmg: pathlib.Path, exe: pathlib.Path, msi: pathlib.Path) -> None:
    if not VERSION_RE.fullmatch(min_from):
        raise SystemExit("min-from 必须是 x.y.z")
    version = version_from_dmg(dmg)
    _, exe_name, msi_name = package_names(version)
    if exe.name != exe_name or msi.name != msi_name:
        raise SystemExit("EXE 与 MSI 必须带上与 DMG 相同的版本")
    body = canonical_bytes(
        version,
        min_from,
        public_key(),
        (read_sidecar(dmg), read_sidecar(exe), read_sidecar(msi)),
    )
    dmg.with_name(f"MenuBarMijia-{version}.update.json").write_bytes(body)


def check_fields(version: str, directory: pathlib.Path) -> None:
    if not VERSION_RE.fullmatch(version):
        raise SystemExit("版本必须是 x.y.z")
    manifest_path = directory / f"MenuBarMijia-{version}.update.json"
    raw = manifest_path.read_bytes()
    try:
        parsed = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SystemExit(f"无法解析更新清单：{error}") from error
    min_from = parsed.get("min_from") if isinstance(parsed, dict) else None
    if not isinstance(min_from, str):
        raise SystemExit("清单缺少 min_from")
    packages = [directory / name for name in package_names(version)]
    expected = canonical_bytes(version, min_from, public_key(), tuple(read_sidecar(path) for path in packages))
    if raw != expected:
        raise SystemExit("更新清单与安装包和校验文件不一致")


def self_test() -> None:
    golden_body = canonical_bytes(
        "1.1.7",
        "1.0.0",
        public_key(),
        ("a" * 64, "b" * 64, "c" * 64),
    )
    golden = GOLDEN.read_bytes()
    if golden_body != golden or len(golden) != 526:
        raise SystemExit(
            f"canonical_bytes 与黄金清单不一致：生成 {len(golden_body)} 字节，文件 {len(golden)} 字节"
        )
    try:
        canonical_bytes("1.2.3", "9.9.9", public_key(), ("a" * 64, "b" * 64, "c" * 64))
    except SystemExit as error:
        if "min_from" not in str(error):
            raise
    else:
        raise SystemExit("min_from 高于 version 时 canonical_bytes 仍成功")
    with tempfile.TemporaryDirectory() as tmp:
        directory = pathlib.Path(tmp)
        version = "1.2.3"
        names = package_names(version)
        payloads = (b"dmg-bytes", b"exe-bytes", b"msi-bytes")
        for name, payload in zip(names, payloads, strict=True):
            path = directory / name
            path.write_bytes(payload)
            digest = hashlib.sha256(payload).hexdigest()
            pathlib.Path(str(path) + ".sha256").write_text(f"{digest}  {name}\n", encoding="utf-8")
        encode("1.0.0", directory / names[0], directory / names[1], directory / names[2])
        check_fields(version, directory)
        dmg = directory / names[0]
        flipped = bytearray(dmg.read_bytes())
        flipped[0] ^= 0xFF
        dmg.write_bytes(flipped)
        try:
            check_fields(version, directory)
        except SystemExit:
            return
        raise SystemExit("改动安装包字节后 check-fields 仍成功")


def main() -> None:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    encode_parser = sub.add_parser("encode")
    encode_parser.add_argument("--min-from", required=True)
    encode_parser.add_argument("--dmg", required=True, type=pathlib.Path)
    encode_parser.add_argument("--exe", required=True, type=pathlib.Path)
    encode_parser.add_argument("--msi", required=True, type=pathlib.Path)
    check_parser = sub.add_parser("check-fields")
    check_parser.add_argument("version")
    check_parser.add_argument("directory", type=pathlib.Path)
    sub.add_parser("self-test")
    args = parser.parse_args()
    if args.command == "encode":
        encode(args.min_from, args.dmg, args.exe, args.msi)
    elif args.command == "check-fields":
        check_fields(args.version, args.directory)
    else:
        self_test()


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        sys.exit(0)
