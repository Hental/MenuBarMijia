# 003 — Smaller, lighter corner handle (visuals only, hit area unchanged)

- **Status**: TODO
- **Commit**: baf7098
- **Severity**: MEDIUM
- **Category**: Physicality & origin (user-requested visual tune)
- **Estimated scope**: 2 files (1 Swift, 1 CSS), ~20 lines

## Problem

The corner arc handle is visually heavier than the iOS Control Center reference and heavier than
the surrounding card chrome, on both platforms:

macOS — `Sources/MenuBarMijiaApp/DeviceLayout.swift:192-204` draws a full 12pt-radius arc with a
4pt stroke at 0.92/0.78 opacity plus a drop shadow, inside a 28pt frame:

```swift
CornerArcHandleShape()
    .stroke(
        colorScheme == .dark ? Color.white.opacity(0.92) : Color.primary.opacity(0.78),
        style: StrokeStyle(lineWidth: 4, lineCap: .round)
    )
    .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
    .frame(width: 28, height: 28)
```

`CornerArcHandleShape` defaults (`Sources/MenuBarMijiaApp/DeviceLayout.swift:193-196`):
`cornerRadius: CGFloat = DesignTokens.Radius.card` (= 12), `inset: CGFloat = 4`.

Windows — `windows/src/ui/styles.css:2361-2407` mirrors the weight: 28px SVG, 4px stroke,
0.92/0.82 opacity, `drop-shadow(0 1px 2px rgba(0, 0, 0, 0.35))`.

The handle also enters from `scale(0)` on Windows (`windows/src/ui/styles.css:2403-2407`):

```css
@keyframes cc-badge-in {
  from {
    transform: scale(0);
  }
}
```

and on macOS via `.transition(.scale.combined(with: .opacity))`
(`Sources/MenuBarMijiaApp/DeviceLayout.swift:266`) whose default scale starts near zero. The
house rule forbids this — `Sources/MenuBarMijiaApp/ThemeAndMotion.swift:51`: "Origin-aware drawer
reveal transition (never scales from 0)".

## Target

Visual arc shrinks; the 28×28 hit area stays exactly as is (accessibility, issue #115). Entrance
starts from `scale(0.92)` + `opacity: 0` on both platforms.

### macOS — `Sources/MenuBarMijiaApp/DeviceLayout.swift`

`CornerArcHandleShape` defaults become (arc occupies the lower-right ~14pt of the 28pt frame):

```swift
struct CornerArcHandleShape: Shape {
    var cornerRadius: CGFloat = 10
    var inset: CGFloat = 8
    ... // path(in:) unchanged
}
```

The stroke block becomes:

```swift
CornerArcHandleShape()
    .stroke(
        colorScheme == .dark ? Color.white.opacity(0.55) : Color.primary.opacity(0.45),
        style: StrokeStyle(lineWidth: 3, lineCap: .round)
    )
    .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
    .frame(width: 28, height: 28)
```

The frame, `contentShape`, gesture, accessibility and paddings stay untouched — hit area is still
28×28 (with the existing `.padding(.bottom/-4) .padding(.trailing, -4)` overhang).

Entrance transition (line 266):

```swift
.transition(.scale(scale: 0.92, anchor: .bottomTrailing).combined(with: .opacity))
```

### Windows — `windows/src/ui/styles.css`

`.cc-resize-handle` (line 2361): keep position/size/z-index/cursor/touch-action; only the color
changes:

```css
.cc-resize-handle {
  /* ...unchanged properties... */
  color: rgba(255, 255, 255, 0.55);
}
```

`.cc-popover.scheme-light .cc-resize-handle` (line 2381):

```css
.cc-popover.scheme-light .cc-resize-handle {
  color: rgba(28, 30, 36, 0.5);
}
```

`.cc-resize-arc` (line 2392): draw a 20px arc centered in the 28px button:

```css
.cc-resize-arc {
  width: 20px;
  height: 20px;
  margin-right: -6px;
  margin-bottom: -6px;
  overflow: visible;
  filter: drop-shadow(0 1px 1px rgba(0, 0, 0, 0.18));
}
```

(The negative margins pin the smaller arc into the bottom-right corner of the hit box; the SVG
`viewBox="0 0 28 28"` and path are unchanged, so the arc geometry scales down proportionally.)

`.cc-resize-arc path` (line 2401): `stroke-width: 4` → `stroke-width: 3`.

`@keyframes cc-badge-in` (line 2403):

```css
@keyframes cc-badge-in {
  from {
    transform: scale(0.92);
    opacity: 0;
  }
}
```

(cc-badge-in is only used by `.cc-resize-handle` after the #115 change — verify with a grep for
`cc-badge-in` before editing; if another consumer exists, add a new `cc-handle-in` keyframes for
the handle instead of editing the shared one.)

## Repo conventions to follow

- macOS presentation constants come from `DesignTokens` (`Sources/MenuBarMijiaApp/DesignTokens.swift`);
  radii from `DesignTokens.Radius`. The arc radius 10 and inset 8 are one-off gesture-chrome
  values passed as Shape parameters (like the existing defaults), not new tokens — do not add
  tokens for them.
- Windows color tokens: the handle colors are literal rgba values matching the existing
  `.cc-resize-handle` block; keep them literal, consistent with the current code.
- Exemplar of a subtle chrome stroke: the card keyboard-focus overlay
  (`Sources/MenuBarMijiaApp/DeviceCardView.swift:183-186`) uses `accent.opacity(0.85)` at
  lineWidth 1.6 — chrome strokes stay well under full opacity.

## Steps

1. `Sources/MenuBarMijiaApp/DeviceLayout.swift` — `CornerArcHandleShape` defaults: `cornerRadius: CGFloat = 10`, `inset: CGFloat = 8`.
2. Same file — stroke: opacity 0.55 (dark) / 0.45 (light), `lineWidth: 3`, shadow opacity 0.15 radius 1.
3. Same file, line 266 — transition becomes `.scale(scale: 0.92, anchor: .bottomTrailing).combined(with: .opacity)`.
4. `windows/src/ui/styles.css` — `.cc-resize-handle` color 0.55; `.scheme-light` variant 0.5; `.cc-resize-arc` 20px + negative margins + lighter drop-shadow; path stroke-width 3; `cc-badge-in` from `scale(0.92)` + `opacity: 0` (or new `cc-handle-in` per the grep note).

## Boundaries

- Do NOT change the 28×28 hit area, `contentShape`, paddings, gesture, or accessibility labels.
- Do NOT touch `cc-jiggle`, `.is-dragging` styles, or any other consumer of `cc-badge-in` without the grep check.
- Do NOT change `ThemeAndMotion.swift` or add DesignTokens entries.
- Do NOT alter the SVG path data — the smaller visual comes from the 20px render size.

## Verification

- **Mechanical**: `swift test --filter longPressOnLightCard` (the real-window test clicks the
  handle at `maxX - 6, maxY - 6` — inside the unchanged hit box; it must stay green).
  `cd windows && npm test && npm run typecheck`. `bash scripts/check.sh --lint-only`
  (design-token gate).
- **Feel check**: rebuild (`bash scripts/build_app.sh`), enter edit mode:
  - the arc reads as a quiet affordance, noticeably lighter than the card border, not a loud badge;
  - the invisible hit area is unchanged: clicking/dragging ~6pt outside the visible arc still
    grabs the handle;
  - entering edit mode: the handle fades/scales in from 92%, never from a point;
  - check both light and dark appearance (footer toggle).
- **Done when**: handle is visually smaller/lighter on both platforms, hit tests unchanged, all
  suites green.
