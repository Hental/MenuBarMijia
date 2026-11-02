## Agent skills

### Issue tracker

GitHub Issues (`jryang1997/MenuBarMijia`) via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default five canonical roles (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context (`GLOSSARY.md` + `docs/adr/` at the repo root). See `docs/agents/domain.md`.

### Coding standards

Read `CODING_STANDARDS.md` when reviewing diffs (`/code-review`) or modifying synthesis, optimistic locking, hotkeys, or grid layout.

### Build & verification

Run `bash scripts/check.sh` for secret scan, mechanical lints, and `swift test`. Run `bash scripts/build_app.sh` to package, sign, and restart `MenuBarMijia.app`. Run `swift scripts/generate_app_icon.swift` when modifying `Resources/AppIcon/AppIcon-*.svg` to regenerate macOS `.icns`, `Assets.car`, README logos, and Windows Tauri icons.

本机存在已知的 `SnapshotTests` 渲染漂移：干净 HEAD 上也同样失配，`bash scripts/check.sh` 会因此变红。本地提交可用 `--no-verify`，以 CI 的 macos job 为准；用 `bash scripts/snapshot-drift-check.sh` 甄别本次改动是否**新增**了失配（输出为空即只有既有漂移）。

### Commit & PR policy

本约定仅适用于此项目。在用户已授权提交的范围内，按改动风险选择直接 push 或 PR，不要求每次代码修改都开 PR。

- 文案、文档、图标、样式微调，以及范围明确的局部交互修复，完成相应检查后可直接 push 到 `main`。交互修复应有针对性验证和用户实机确认；按影响范围判断风险，不按代码行数判断。
- 登录、凭据与钥匙串、安全权限、设备控制、撤销、定时任务、数据迁移、自动更新、签名、打包发布、跨平台逻辑，以及牵涉多个模块的改动，走 PR，检查通过后再合并。
- 检查失败原因尚未确认时，走 PR 排查，解决后再合并。已复现并确认与本轮无关的既有失败，需记录证据及例外原因；跳过检查不是默认流程。
- 一个完整问题对应一次提交或一个 PR；同一问题的后续调整继续使用原 PR。
- 直接 push 后确认云端检查的最终结果；交付时区分“已推送”与“检查已通过”。直接 push 不等于发布新版本。

### Worktrees

- `git worktree list` 里登记给其他会话的分支（如 Codex 的 `wt/dev` 工作树）归该代理所有：审计只读，不改它的文件。
- 接管前先确认对方已安静：无新提交且 `git status` 干净。对方仍在迭代时，在自己的分支副本上完成改动再推回。
- 对方提交在你审计途中落地，就按最新提交重读后再下结论，不基于旧快照。
