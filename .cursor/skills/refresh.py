#!/usr/bin/env python3
"""Copy pstack, tstack, and mattpocock skills into this directory."""

import argparse
import re
import shutil
import sys
from pathlib import Path

PSTACK_BLOB = "https://github.com/cursor/plugins/blob/main/pstack"
NAME_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
LINK_RE = re.compile(r"\[[^\]]*\]\(([^)\s]+)\)")
SOURCES = ("pstack", "tstack", "mattpocock")


def dest_name(source: str, folder: str) -> str:
    if source == "mattpocock":
        return folder if folder.startswith("mp-") else f"mp-{folder}"
    return folder


def split_frontmatter(text: str, path: Path) -> tuple[str, str, str]:
    if not text.startswith("---\n"):
        raise SystemExit(f"{path} has no YAML frontmatter")
    close = text.find("\n---", 4)
    if close == -1:
        raise SystemExit(f"{path} has unclosed frontmatter")
    return text[:4], text[4:close], text[close:]


def set_name(text: str, path: Path, name: str) -> str:
    prefix, frontmatter, suffix = split_frontmatter(text, path)
    updated, count = re.subn(
        r"(?m)^name:.*$", f"name: {name}", frontmatter, count=1
    )
    if count != 1:
        raise SystemExit(f"{path} has no frontmatter name")
    return prefix + updated + suffix


def description_ok(frontmatter: str) -> bool:
    match = re.search(r"(?m)^description:[ \t]*(.*)$", frontmatter)
    if not match:
        return False
    inline = match.group(1).strip().strip("\"'")
    if inline and inline not in {">", ">-", "|", "|-", "|+"}:
        return True
    rest = frontmatter[match.end() :]
    for line in rest.splitlines():
        if line and not line.startswith((" ", "\t")):
            break
        if line.strip():
            return True
    return False


def rewrite_plugin_links(text: str) -> str:
    text = text.replace(
        "](../../README.md)", f"]({PSTACK_BLOB}/README.md)"
    )
    return text.replace("](../../docs/", f"]({PSTACK_BLOB}/docs/")


def copy_skill(source_dir: Path, target: Path) -> int:
    if target.exists():
        shutil.rmtree(target)
    shutil.copytree(source_dir, target)
    return sum(1 for path in target.rglob("*") if path.is_file())


def clear_skills(dest: Path) -> None:
    for child in dest.iterdir():
        if child.is_dir() and (child / "SKILL.md").is_file():
            shutil.rmtree(child)


def refresh(pack: Path, dest: Path) -> dict[str, int]:
    for source in SOURCES:
        if not (pack / source).is_dir():
            raise SystemExit(f"{pack} is missing {source}/")
    clear_skills(dest)
    counts: dict[str, int] = {}
    for source in SOURCES:
        total = 0
        for skill_dir in sorted(path for path in (pack / source).iterdir() if path.is_dir()):
            skill_md = skill_dir / "SKILL.md"
            if not skill_md.is_file():
                continue
            name = dest_name(source, skill_dir.name)
            if not NAME_RE.fullmatch(name):
                raise SystemExit(f"illegal skill name {name}")
            target = dest / name
            total += copy_skill(skill_dir, target)
            skill_path = target / "SKILL.md"
            skill_path.write_text(set_name(skill_path.read_text(), skill_path, name))
        license_path = pack / source / "LICENSE"
        if license_path.is_file():
            shutil.copyfile(license_path, dest / f"{source}-LICENSE")
            total += 1
        counts[source] = total
    for skill_md in dest.glob("*/SKILL.md"):
        original = skill_md.read_text()
        rewritten = rewrite_plugin_links(original)
        if skill_md.parent.name == "tstack-full-stop":
            rewritten = rewritten.replace(
                "../full-send/SKILL.md", "../tstack-full-send/SKILL.md"
            )
        if rewritten != original:
            skill_md.write_text(rewritten)
    return counts


def skill_dirs(dest: Path) -> list[Path]:
    return sorted(
        path for path in dest.iterdir() if path.is_dir() and (path / "SKILL.md").is_file()
    )


def check_links(dest: Path, errors: list[str]) -> None:
    root = dest.resolve()
    for markdown in dest.rglob("*.md"):
        if markdown.parent == dest:
            continue
        for match in LINK_RE.finditer(markdown.read_text(errors="replace")):
            target = match.group(1)
            if target.startswith(("http://", "https://", "mailto:", "#")):
                continue
            if re.fullmatch(r"[a-z][a-z0-9+.-]*:.+", target):
                continue
            path = target.split("#", 1)[0]
            if "/" not in path and "." not in path:
                continue
            if path.startswith("./src/") or path.startswith("src/"):
                continue
            resolved = (markdown.parent / path).resolve()
            if ".." in Path(path).parts:
                try:
                    resolved.relative_to(root)
                except ValueError:
                    errors.append(f"{markdown.relative_to(dest)} escapes skills: {target}")
                    continue
                if not resolved.exists():
                    errors.append(f"{markdown.relative_to(dest)} missing link {target}")
                continue
            if not resolved.exists():
                errors.append(f"{markdown.relative_to(dest)} missing link {target}")


def check(dest: Path) -> None:
    errors: list[str] = []
    names: list[str] = []
    for skill_dir in skill_dirs(dest):
        skill_md = skill_dir / "SKILL.md"
        text = skill_md.read_text()
        _, frontmatter, _ = split_frontmatter(text, skill_md)
        match = re.search(r"(?m)^name:[ \t]*(.+)$", frontmatter)
        name = match.group(1).strip().strip("\"'") if match else ""
        if name != skill_dir.name:
            errors.append(f"{skill_dir.name} frontmatter name is {name!r}")
        if not NAME_RE.fullmatch(skill_dir.name):
            errors.append(f"illegal directory name {skill_dir.name}")
        if not description_ok(frontmatter):
            errors.append(f"{skill_dir.name} has no description")
        names.append(skill_dir.name)
    duplicates = sorted({name for name in names if names.count(name) > 1})
    if duplicates:
        errors.append(f"duplicate names: {', '.join(duplicates)}")
    for license_name, holder in (
        ("pstack-LICENSE", "Lauren Tan"),
        ("mattpocock-LICENSE", "Matt Pocock"),
    ):
        license_path = dest / license_name
        if not license_path.is_file():
            errors.append(f"missing {license_name}")
            continue
        body = license_path.read_text()
        if "MIT License" not in body or holder not in body:
            errors.append(f"{license_name} is not the {holder} MIT license")
    full_stop = dest / "tstack-full-stop" / "SKILL.md"
    if full_stop.is_file() and "../full-send/SKILL.md" in full_stop.read_text():
        errors.append("tstack-full-stop still points at ../full-send/SKILL.md")
    check_links(dest, errors)
    if errors:
        raise SystemExit("skill check failed:\n" + "\n".join(errors))
    print(f"ok {len(names)} skills")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pack", nargs="?", type=Path, help="directory with pstack/, tstack/, and mattpocock/")
    parser.add_argument("--check", action="store_true", help="validate the skills directory without copying")
    parser.add_argument("--dest", type=Path, help="skills directory, default is this script's directory")
    args = parser.parse_args()
    dest = (args.dest or Path(__file__).resolve().parent).resolve()
    if not args.check:
        if args.pack is None:
            raise SystemExit("pass a skill pack directory, or pass --check")
        counts = refresh(args.pack.resolve(), dest)
        for source in SOURCES:
            print(f"{source} {counts[source]}")
    check(dest)


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        sys.exit(0)
