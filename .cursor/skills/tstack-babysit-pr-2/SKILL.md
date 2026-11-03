---
name: tstack-babysit-pr-2
description: >-
  Use when babysitting, watching, or driving a GitHub PR through CI and review
  bots to merge-ready (Theo tstack babysit-pr, adapted for this bot).
---
# tstack babysit-pr (Grok Bot)

Source: https://github.com/t3dotgg/tstack (skill `babysit-pr`). Local copy: `/home/box/agent-data/workflows/tstack-babysit-pr/` with `scripts/pr-wait`.
Also mirror: [tstack babysit-pr](sand-workflow:tstack-babysit-pr) folder under workflows.

## MenuBarMijia merge gate (overrides tstack Greptile default)

Ready means all of:
- Required CI check runs on the current head are green (skipped OK).
- Codex (`chatgpt-codex-connector`) reviewed the **current** tip with no unresolved objections. If Codex has not reviewed this tip, comment `@codex review` once and wait. Do not `@codex` again if a review on this tip already exists.
- No merge conflicts; rebase when BEHIND/DIRTY, then re-wait.

Do **not** wait for Greptile or Macroscope unless the repo actually uses them.

## Waiting

Never write your own sleep poller. Use one watcher per PR:

```bash
/home/box/agent-data/workflows/tstack-babysit-pr/scripts/pr-wait <pr> --repo jryang1997/MenuBarMijia --until green
```

Then verify the Codex tip review via GitHub tools. For MenuBarMijia prefer `green` + Codex, not tstack's default `ready` (Greptile).

pstack alternative: poteto-mode Babysit playbook. Prefer one watcher stack per PR.

## Reviews

Only act on checks/comments newer than the latest push. Verify bot findings against source. Fix real issues; dismiss false positives with a written reason. Comment tone: `/home/box/agent-data/workflows/tstack-leaving-pr-comments/SKILL.md`.

## Merge

Merge only under Jerry's standing Codex-first + CI-green rule, or an explicit full-send grant for that PR. Otherwise stop at merge-ready and report the PR URL. Stay quiet while waiting.
