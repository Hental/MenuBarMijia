# Animation Plans — corner-handle resize polish (#115 follow-up)

Audit of the resize-gesture motion chain on macOS + Windows after the user reported the
interaction still "not smooth enough" and asked for a smaller, lighter handle. Audit commit:
`baf7098`. Effort: standard, focused on the resize chain (findings vetted at file:line).

## Plans

| # | Title | Severity | Status | Depends on |
|---|---|---|---|---|
| 001 | Continuous resize preview across steps (kill the per-step scale snap) | HIGH | DONE (f9ceef5) | — |
| 002 | Unify resize springs on the house spring (AppleMotion.snappySpring) | HIGH | DONE (f9ceef5) | — |
| 003 | Smaller, lighter corner handle (visuals only, hit area unchanged) | MEDIUM | DONE (f9ceef5) | — |
| 004 | Pause the jiggle on the card being resized | MEDIUM | DONE (f9ceef5) | — |
| 005 | Localize resize tracking state (stop per-pointermove panel re-render) | MEDIUM | DONE (f9ceef5) | 001 |

## Recommended execution order

1. **001** — the main "not smooth" fix: cumulative preview progress across steps, both platforms.
2. **002** — spring cohesion; independent of 001, can run in parallel.
3. **003** — visual tune the user asked for (smaller arc, lighter stroke, scale(0.92) entrances).
4. **004** — jiggle pause while resizing; touches the same `LayoutEditable`/`app.ts` regions as
   001 but different lines; safe after 001.
5. **005** — perf refactor; **must run after 001** (it restructures the preview state 001 wires).

001 + 002 together are the feel fix; 003 is the look fix; 004/005 are polish. After each plan:
run its mechanical checks, rebuild with `bash scripts/build_app.sh`, and feel-check per the plan.

## Out-of-scope observations (not planned)

- macOS handle hover has no cursor feedback (Windows has `cursor: nwse-resize`); SwiftUI macOS 14
  has no diagonal-resize cursor without AppKit pushing — low value, skipped.
- Panel window height jumps when a card steps between sizes; a spring there touches
  `MenuBarPanelController.updatePanelSize` — separate work item if wanted.
