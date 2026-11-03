# Vendored Cursor skills

Cursor loads each skill from `.cursor/skills/<name>/SKILL.md`. The frontmatter `name` matches that directory. This tree follows the project skill layout in the [Agent Skills](https://cursor.com/docs/skills) docs.

## Sources

These skills come from three sources. The vendored date is 2026-11-03.

- pstack is by Lauren Tan. The source is https://github.com/cursor/plugins/tree/main/pstack. The MIT license is `pstack-LICENSE`.
- tstack is the set at https://github.com/t3dotgg/tstack. Each directory name starts with `tstack-`, and the frontmatter `name` matches it.
- mattpocock skills are by Matt Pocock. The source is https://github.com/mattpocock/skills. The MIT license is `mattpocock-LICENSE`. Each directory and its frontmatter `name` start with `mp-`.

The pack includes the MIT licenses for pstack and for mattpocock. Those two files sit next to the skills.

## Refresh the skills

Refresh from a pack directory that contains `pstack/`, `tstack/`, and `mattpocock/`.

1. Run `python3 .cursor/skills/refresh.py <pack>`.
2. Set the vendored date in this file to the day of that run.
3. Run `python3 .cursor/skills/refresh.py --check`.

The script copies each skill with its helper files and writes the two license files next to the skills. Mattpocock directories and frontmatter names gain an `mp-` prefix. The script sets each tstack frontmatter `name` to its directory name. `tstack-full-stop` links to `tstack-full-send`. `poteto-help` links to the pstack README and guide on GitHub.
