#!/usr/bin/env python3
"""Compare both README capability tables with docs/capabilities.json."""

import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "docs/capabilities.json"
TABLES = (
    ("README.md", "| Feature Area |", "en"),
    ("README.zh-CN.md", "| 功能维度 |", "zh"),
)


def status(cell: str) -> str | None:
    if "✅" in cell:
        return "supported"
    if "⚠" in cell:
        return "partial"
    if "—" in cell or "❌" in cell:
        return "unsupported"
    return None


def read_rows(path: str, header: str) -> list[tuple[str, str | None, str | None]]:
    lines = (ROOT / path).read_text(encoding="utf-8").splitlines()
    try:
        start = next(index for index, line in enumerate(lines) if line.startswith(header))
    except StopIteration:
        raise SystemExit(f"❌ {path}: 找不到能力表表头 {header!r}")

    rows: list[tuple[str, str | None, str | None]] = []
    for line in lines[start + 1:]:
        if not line.startswith("|"):
            break
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if len(cells) != 4:
            continue
        if cells[0].startswith(":---") or cells[0].startswith("---"):
            continue
        rows.append((cells[0].strip("*").strip(), status(cells[1]), status(cells[2])))
    return rows


def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    expected = manifest.get("rows")
    if not isinstance(expected, list) or not expected:
        raise SystemExit("❌ docs/capabilities.json 缺少 rows")

    errors: list[str] = []
    parsed: dict[str, list[tuple[str, str | None, str | None]]] = {}
    for path, header, key in TABLES:
        rows = read_rows(path, header)
        parsed[key] = rows
        if len(rows) != len(expected):
            errors.append(f"{path}: {len(rows)} 行，capabilities.json 有 {len(expected)} 行")
        for index, (row, wanted) in enumerate(zip(rows, expected)):
            label, macos, windows = row
            if macos is None or windows is None:
                errors.append(f"{path} 第 {index + 1} 行 {label!r}: 无法识别状态标记")
                continue
            if label != wanted[key]:
                errors.append(
                    f"{path} 第 {index + 1} 行标签是 {label!r}，manifest 是 {wanted[key]!r}"
                )
            if (macos, windows) != (wanted["macos"], wanted["windows"]):
                errors.append(
                    f"{path} 第 {index + 1} 行 {label!r}: "
                    f"README={macos}/{windows}，manifest={wanted['macos']}/{wanted['windows']}"
                )

    for index, (english, chinese) in enumerate(zip(parsed["en"], parsed["zh"])):
        if english[1:] != chinese[1:]:
            errors.append(
                f"第 {index + 1} 行中英文状态不一致: {english[1:]!r} vs {chinese[1:]!r}"
            )

    if errors:
        print("❌ 能力表与 docs/capabilities.json 不一致：")
        for error in errors:
            print(f"  - {error}")
        print("请同时更新 README.md、README.zh-CN.md 与 docs/capabilities.json。")
        return 1
    print(f"✅ {len(expected)} 行能力状态与两份 README 一致。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
