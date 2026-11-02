# Coding Standards

Reviewed by `/code-review` (Standards axis). Mechanical rules (secret scanning, `kVK_*` key constants, `UNUserNotificationCenter` `.app` bundle guard, and `swift test`) are enforced deterministically by `scripts/check.sh`. The rules below cover architectural and domain judgement calls.

## 1. Entity Registry Exclusions Block State Fallbacks

When synthesizing Home Assistant entities in `Sources/MijiaCore/DeviceSynthesizer.swift` with a primary pass over `snapshot.entityRegistry` followed by a fallback pass over `snapshot.states`:

- Record every matched registry `entity_id` into the seen set (`seen...Ids`) **before** skipping `disabled_by != nil || hidden_by != nil` entries.
- Skipping before recording leaks disabled or hidden entities back into the UI through the `states` fallback loop.

## 2. Bidirectional Optimistic Lock on Snapshot Undo

When restoring a `previousDevices` snapshot in `HomeStore` (`UndoBanner` / `undoTurnAllOff`):

- Call `lockOptimistic(dev.id, duration: .seconds(3.0))` for **every device whose state differs** between current `devices` and `banner.previousDevices`.
- Locking only `where dev.isActiveOn` fails when undoing an action (such as `QuickAction.softNightLight`) that turned a previously-off device on, exposing the restored off-state to stale WebSocket frames.

## 3. System Global Resource Lifecycle

System-wide registrations (such as Carbon `RegisterEventHotKey` in `HotkeyAndNotificationManager`) must bind their active registration lifecycle to their preference toggle:

- Call `UnregisterEventHotKey` immediately when `enableGlobalHotkey` is set to `false`, and re-register when set to `true`.
- Leaving a global hotkey registered while ignoring the callback hijacks the key chord from other macOS applications.

## 4. CompactTile Two-Column Alignment

In `ControlCenterPanel` when `isCompactGridMode` is active:

- Devices with an open detail drawer (`expandedDeviceId == dev.id`) render as full-width `.single(dev)` rows (`isCompactTile: false`).
- Unexpanded devices render in two-column `.pair(left, right)` rows (`isCompactTile: true`). When an unexpanded tile has no partner, pair it with `nil` and render a half-width `Color.clear.frame(maxWidth: .infinity)` placeholder so single tiles never stretch full-width.

## 5. Domain Vocabulary & Single Source of Truth

- Keep `MijiaCore` free of `AppKit` / `SwiftUI` imports so all synthesis, optimistic locking, and store state remain fast-testable via `MockHomeProvider`.
- Align type and property names with [`GLOSSARY.md`](GLOSSARY.md) and [`docs/adr/0001-ha-as-single-source-of-truth.md`](docs/adr/0001-ha-as-single-source-of-truth.md).

## 6. Cross-Platform Golden Corpora & AI Provider Parity

When adding or changing spoken command, delay, undo, habit-memory, proactive-suggestion, MIoT synthesis, MIoT command mapping, or AI provider preset rules in `Sources/MijiaCore/LocalIntentParser.swift`, `Sources/MijiaCore/UserHabitMemory.swift`, `Sources/MijiaCore/AssistantSchedule.swift`, `Sources/MijiaCore/AssistantConfig.swift`, `Sources/MijiaCore/MiCloud/MiotSynthesizer.swift`, `Sources/MijiaCore/MiCloud/MiotCommandMapper.swift`, `windows/src/core/assistant.ts`, or `windows/src/core/miCloudClient.ts`:

- Add a representative test case to [`Tests/Fixtures/intent_golden.json`](Tests/Fixtures/intent_golden.json) or [`Tests/Fixtures/miot_golden.json`](Tests/Fixtures/miot_golden.json) so both `Tests/MijiaCoreTests/GoldenCorpusTests.swift` and `windows/tests/core.test.ts` assert the exact same behavior. AI provider preset rules (domain matching, which hosts may receive API keys) live in [`Tests/Fixtures/provider_golden.json`](Tests/Fixtures/provider_golden.json); Mi cloud region codes/order in [`Tests/Fixtures/region_golden.json`](Tests/Fixtures/region_golden.json); the Jev `/v1/systemone` request skeleton in [`Tests/Fixtures/ai_request_golden.json`](Tests/Fixtures/ai_request_golden.json); habit-memory record/unrecord and the Top-4 proactive engine in [`Tests/Fixtures/habit_golden.json`](Tests/Fixtures/habit_golden.json) — all asserted by `Tests/MijiaCoreTests/GoldenCorpusTests.swift` and …
- Keep `AssistantProviderPreset.allCases.map(\.rawValue)` (macOS) and `ASSISTANT_PROVIDER_PRESETS.map(p => p.id)` (Windows) identical in order and membership, and isolate user-saved API keys per provider (`KeychainHelper.assistantProviderAPIKeyAccount(for:)`).
- Never let one platform silently diverge on Chinese or English command parsing, delay limits (`<= 86400s`), unknown-word fallback (`nil` / `null`), MIoT `0`/`1` boolean coercion, multi-service property resolution, or command range/step clamping.
- GrokBall emotion priority and radial slot order live in [`Tests/Fixtures/grok_ball_golden.json`](Tests/Fixtures/grok_ball_golden.json), asserted by both `GoldenCorpusTests` and `windows/tests/core.test.ts`. Preserve the upstream MIT notice when updating the bundled engine or native geometry.

## 7. Scheduled Command Persistence & Missed-Timer Confirmation

When modifying `ScheduledCommand` or `HomeStore+Assistant.swift`:

- Persist both `scheduledCommands` and unconfirmed `missedScheduledCommands` to `UserDefaults` (`ScheduledCommand.storageKey`) on every schedule, fire, restore, confirm, dismiss, or cancel transition.
- Never auto-execute an expired timer silently on launch; keep it in `missedScheduledCommands` (and on disk across restarts) until the user explicitly confirms (`runMissedScheduledCommand`) or dismisses (`dismissMissedScheduledCommand`).
- The same applies after the Mac sleeps: `Task.sleep` keeps counting during sleep, so a timer task can wake up long after its `fireDate`. A timer that wakes more than `HomeStore.lateTimerGrace` (60 s) late goes to `missedScheduledCommands` instead of running. Tests simulate this with `assistantNow`.

## 8. macOS 14+ Adaptive Glass Boundary

- Isolate macOS 26 `.glassEffect(` and `GlassEffectContainer` calls inside `Sources/MenuBarMijiaApp/ThemeAndMotion.swift` (`View.adaptiveGlass` and `AdaptiveGlassContainer`), guarded by `#available(macOS 26.0, *)` with Material fallback for macOS 14 and 15. Enforced mechanically by `scripts/check.sh`.

## 9. Tests Must Not Race Product Timers

When a test asserts on state that a production timer can change (undo banner expiry, scheduled commands, cooldowns, polling):

- Freeze the timer through an existing seam (`HomeStore.pauseUndoBannerCountdown()`, `assistantNow`, `controlDebounceInterval`), or
- Poll a deterministic signal that the path under test actually produces. When the failure path records nothing, the reliable signal is "the timer is frozen and the assertion runs immediately", not a spin on a success-only collection.

A wall-clock sleep before the assertion is the failure mode: on a loaded CI runner the sleep stretches past the timer's expiry, so the assertion fails nondeterministically while passing locally. This shipped once: `failedQuickActionRecordsNothing` spun on `executedCommands` (empty on failures) for 18 s in CI, past the 10 s banner expiry.

## 10. Overlay Geometry Has One Owner

Placement math that reserves space and the view that draws inside it must read the same dimensions:

- Pill sizes and spacing live once beside the content (`GrokBallSuggestionMetrics`); placement math derives its column, row, and footprint from them instead of repeating literals like 132, 44, 206, and 558.
- A view never hardcodes a size the placement reserves. When the two drift apart the content clips silently: #123's English empty state needed 65 pt inside a 44 pt row.
- Empty and fallback states fill the reserved width (`.frame(maxWidth: .infinity)`) so they reflow instead of assuming a fixed column.

