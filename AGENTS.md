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

Run `bash scripts/check.sh` for secret scan, mechanical lints, and `swift test`. On this Mac the renderer never matches the CI-recorded snapshot baselines, so use `bash scripts/check.sh --skip-snapshots` for a green local gate; CI still records and compares them. The pre-commit hook runs the same snapshot-skipping gate. Run `bash scripts/install_local_app.sh` to build, verify, and install into the bundle the user launches (it keeps the previous version for rollback); `bash scripts/build_app.sh` only packages the bundle inside the worktree. Run `swift scripts/generate_app_icon.swift` when modifying `Resources/AppIcon/AppIcon-*.svg` to regenerate macOS `.icns`, `Assets.car`, README logos, and Windows Tauri icons.

CI 的快照比对以 CI 录制的结果为准。本机渲染漂移时，用 `bash scripts/snapshot-drift-check.sh` 判断是否**新增**了失配（输出为空即只有既有漂移）。漂移甄别回答不了「这次 UI 改动是否欠一批新基线」：改到 `Sources/MenuBarMijiaApp/` 就要按 `bash scripts/check_snapshot_baselines.sh` 的提示重录快照，CI 的 `snapshot-baselines` 工作流守这一条。`check.sh` 会跑完 Swift 与 Windows 两端再汇总失败。

### Tooling

本仓库的 Swift 与 Rust 没有语言服务器：引用与定义检索用 `grep` 或 `xd://ast_grep`，不要反复尝试 `xd://lsp`。

### Commit & PR policy

本约定仅适用于此项目。在用户已授权提交的范围内，按改动风险选择直接 push 或 PR，不要求每次代码修改都开 PR。

- 文案、文档、图标、样式微调，以及范围明确的局部交互修复，完成相应检查后可直接 push 到 `main`。交互修复应有针对性验证和用户实机确认；按影响范围判断风险，不按代码行数判断。
- 登录、凭据与钥匙串、安全权限、设备控制、撤销、定时任务、数据迁移、自动更新、签名、打包发布、跨平台逻辑，以及牵涉多个模块的改动，走 PR，检查通过后再合并。
- 检查失败原因尚未确认时，走 PR 排查，解决后再合并。已复现并确认与本轮无关的既有失败，需记录证据及例外原因；跳过检查不是默认流程。
- 一个完整问题对应一次提交或一个 PR；同一问题的后续调整继续使用原 PR。
- 直接 push 后确认云端检查的最终结果；交付时区分“已推送”与“检查已通过”。直接 push 不等于发布新版本。
- PR 创建后用 `gh pr checks <n>`（或 `gh pr view <n> --json statusCheckRollup`）确认云端结果；首次查询为空时按退避重试，不要据此报告「还没有 CI」。

### Worktrees

- `git worktree list` 里登记给其他会话的分支（如 Codex 的 `wt/dev` 工作树）归该代理所有：审计只读，不改它的文件。
- 接管前先确认对方已安静：无新提交且 `git status` 干净。对方仍在迭代时，在自己的分支副本上完成改动再推回。
- 对方提交在你审计途中落地，就按最新提交重读后再下结论，不基于旧快照。

## Cursor Cloud specific instructions

Cloud agents are Linux. `scripts/build_app.sh`, `scripts/install_local_app.sh`, and a repo-root `swift test` need the macOS SDK (CI uses macos-26). The Windows Tauri installer (`cargo test`, `npx tauri build`) stays on Windows CI.

On Linux, `bash scripts/check.sh --skip-snapshots` (the pre-commit hook) runs `scripts/linux-check/run.sh` instead of `swift test`. That is the same MijiaCore suite as CI's `linux-core` job (Swift 6.1). It still runs the Windows frontend tests when `windows/node_modules` is present.

Other Linux checks:

- `bash scripts/check.sh --lint-only` — secret scan and mechanical lints only.
- `bash scripts/test_nas_setup.sh` — NAS packaging safety. It stubs network commands; no NAS host is required.
- `npm ci --prefix windows`, then `npm test --prefix windows` and `npm run build --prefix windows` — Windows frontend (Node 22). `npm run build` is not part of the pre-commit hook.

`npm run dev --prefix windows` serves the tray UI at port 1420 (`strictPort`). The dev server is started on boot. First launch shows onboarding; “Preview the demo” / “先看演示预览” opens the offline demo home, and clicking a device card toggles it. Mi Cloud QR login and Home Assistant need a real account and are not part of this setup.

Swift's clang selects the newest GCC. This image has GCC 14, so `libstdc++-14-dev` must be installed or `swift-crypto` fails with `cstdio` file not found. The environment install script installs Swift 6.1.3 and that package. No secrets are required for the checks above.
