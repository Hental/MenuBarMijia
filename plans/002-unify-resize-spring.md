# 002 — Unify resize springs on the house spring (AppleMotion.snappySpring)

- **Status**: TODO
- **Commit**: baf7098
- **Severity**: HIGH
- **Category**: Easing & duration / Cohesion & tokens
- **Estimated scope**: 1 file (Swift), 2 lines; plus 1 TS line for the preview spring-back token

## Problem

Two different bouncy springs drive the same layout change on macOS, and both overshoot:

`Sources/MenuBarMijiaApp/ControlCenterPanel.swift:886` — the size step itself:

```swift
withAnimation(.spring(response: 0.34, dampingFraction: 0.76)) {
    store.expandedDeviceId = nil
    liveSizes = sizes
}
```

`Sources/MenuBarMijiaApp/ControlCenterPanel.swift:1001` — the grid re-layout of every neighbour:

```swift
.animation(.spring(response: 0.38, dampingFraction: 0.78), value: ordered.map { "\($0.id):\(spanMap[$0.id] ?? 6)" })
```

dampingFraction 0.76/0.78 ≈ 24% overshoot. On a grid, overshoot makes the resized card and its
neighbours briefly overlap and settle back — reads as wobble, not springiness. The repo's own house
spring is critically damped and exists precisely for this
(`Sources/MenuBarMijiaApp/ThemeAndMotion.swift:42-43`):

```swift
/// Critically damped spring (damping ~ 0.94, response 0.26s) — smooth, interruptible, no distracting overshoot
public static let snappySpring = Animation.spring(response: 0.26, dampingFraction: 0.94, blendDuration: 0.08)
```

Additionally, the macOS preview scale returns to 1 instantly when the gesture ends
(`activeResize = nil` in `endResize`, `Sources/MenuBarMijiaApp/ControlCenterPanel.swift:777-779`)
— a second snap. Windows already springs the preview back but with a hand-typed curve that
duplicates the existing token (`windows/src/ui/app.ts`, `clearPreviewTransform`):

```ts
tile.style.transition = "transform 240ms cubic-bezier(0.2, 0.9, 0.3, 1.15)";
```

## Target

- Both macOS springs become `AppleMotion.snappySpring` (response 0.26, dampingFraction 0.94 — no
  overshoot, interruptible, retargets from current presentation).
- The preview scale spring-back on macOS gesture end animates with the same house spring instead
  of snapping.
- Windows preview spring-back uses the existing `--ease-spring` token
  (`cubic-bezier(0.22, 1, 0.36, 1)`, `windows/src/ui/styles.css:28`), duration 240ms unchanged.

### macOS — `Sources/MenuBarMijiaApp/ControlCenterPanel.swift`

Line 886:

```swift
withAnimation(AppleMotion.snappySpring) {
    store.expandedDeviceId = nil
    liveSizes = sizes
}
```

Line 1001:

```swift
.animation(AppleMotion.snappySpring, value: ordered.map { "\($0.id):\(spanMap[$0.id] ?? 6)" })
```

In `endResize` (~line 776-797), wrap the state reset so the preview eases back instead of snapping:

```swift
private func endResize(_ deviceId: String, translation: CGSize) {
    guard let current = activeResize, current.deviceId == deviceId else { return }
    withAnimation(AppleMotion.snappySpring) {
        activeResize = nil
        activeResizeTranslation = .zero
    }
    ... // rest unchanged
}
```

Note: `endResize` is called from two places — the handle's own `.onEnded` and
`tileDragGesture.onEnded` (~line 712). Both go through this one function; no other changes needed.
The tap-cycle path (`moved < 5` → `cycleSize`) runs after the state reset inside the same
animation transaction; verify the tap cycle still animates (it calls `setTileSize` which has its
own `withAnimation`).

### Windows — `windows/src/ui/app.ts`, in `clearPreviewTransform`

```ts
if (animateBack) {
  tile.style.transition = "transform 240ms var(--ease-spring)";
  tile.style.transform = "";
  previewCleanupTimer = window.setTimeout(() => { tile.style.transition = ""; }, 260);
}
```

## Repo conventions to follow

- All shared macOS motion constants live in `AppleMotion` (`Sources/MenuBarMijiaApp/ThemeAndMotion.swift:40-52`);
  ad-hoc `.spring(response:dampingFraction:)` at call sites is the exception, not the rule.
- All shared Windows easing curves live as CSS custom properties under `:root`
  (`windows/src/ui/styles.css:27-28`); hand-typed `cubic-bezier(...)` in JS strings is the exception.
- Exemplar: `.animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.85), value: isOn)`
  shows the reduce-motion gate pattern — `AppleMotion` consumers rely on the panel-level
  `.transaction { if reduceMotion { $0.disablesAnimations = true } }`, so no extra gate is needed here.

## Steps

1. `Sources/MenuBarMijiaApp/ControlCenterPanel.swift:886` — swap the spring for `AppleMotion.snappySpring`.
2. Same file, line 1001 — swap the grid `.animation` spring for `AppleMotion.snappySpring`.
3. Same file, `endResize` — wrap `activeResize = nil` / `activeResizeTranslation = .zero` in `withAnimation(AppleMotion.snappySpring)`.
4. `windows/src/ui/app.ts` — in `clearPreviewTransform`, replace the hand-typed bezier with `var(--ease-spring)`.

## Boundaries

- Do NOT touch `AppleMotion` itself or add a new spring token.
- Do NOT change the jiggle animation, FLIP reorder animation (340ms), or entrance animations.
- Do NOT modify `PanelHeight`/window-resize animation.
- Do NOT change `setTileSize`'s haptic logic.

## Verification

- **Mechanical**: `swift test --skip SnapshotTests` — all suites green (especially
  `MenuBarPanelControllerTests`, which drives the real window; it passes with
  `reduceMotionOverride` so spring swaps are safe). `cd windows && npm test && npm run typecheck`.
- **Feel check**: rebuild (`bash scripts/build_app.sh`), enter edit mode:
  - tap the handle to cycle sizes: the card and its neighbours resize with a single crisp settle,
    no bounce-past-and-return;
  - drag across a step: card and neighbours settle together, never overlapping mid-flight;
  - drag 20pt and release without crossing: the preview scale glides back to 1 (no snap);
  - Rapidly tap the handle 5 times: motion retargets smoothly, never restarts from zero.
- **Done when**: no visible overshoot on any resize path, and both suites pass.
