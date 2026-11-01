# 004 — Pause the jiggle on the card being resized

- **Status**: TODO
- **Commit**: baf7098
- **Severity**: MEDIUM
- **Category**: Purpose & frequency / Performance
- **Estimated scope**: 3 files (2 Swift, 2 TS), ~15 lines

## Problem

In edit mode every card runs an infinite ±0.9° jiggle animation. When the user grabs a card's
resize handle, that card keeps jiggling **under** the tracking preview scale — two competing
motions on the one element the user is watching. Dragging an already-jiggling corner makes the
arc handle wander ±0.9° relative to the pointer, which reads as slop.

macOS — the jiggle only pauses for card-reorder drags
(`Sources/MenuBarMijiaApp/DeviceLayout.swift:276-280`):

```swift
private func jiggling<V: View>(_ view: V) -> some View {
    if editing && !reduceMotion && !isDragging {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            view.rotationEffect(.degrees(sin(t * 2 * .pi * 3.6 + phase) * 1.1))
        }
    } else {
        view
    }
}
```

Windows — same gap (`windows/src/ui/styles.css:2332-2341`); only `.is-dragging` stops it:

```css
.cc-popover.is-editing .cc-tile {
  animation: cc-jiggle 280ms ease-in-out infinite alternate;
  animation-delay: var(--jd);
  cursor: grab;
  overflow: visible;
}
```

A side benefit: the macOS `TimelineView(.animation)` re-renders the card every display frame;
pausing it for the resized card removes that per-frame work exactly while the preview scale is
also updating.

## Target

While a card's resize handle is held, that card's jiggle is suspended (the tracking preview scale
remains — it is the gesture feedback). It resumes on release/cancel. All other cards keep
jiggling.

### macOS — `Sources/MenuBarMijiaApp/DeviceLayout.swift`

Add an `isResizing` parameter to `LayoutEditable` (next to `isDragging`):

```swift
let isDragging: Bool
var isResizing: Bool = false
let dragOffset: CGSize
```

The jiggle gate (line 277) becomes:

```swift
if editing && !reduceMotion && !isDragging && !isResizing {
```

`Sources/MenuBarMijiaApp/ControlCenterPanel.swift` — `editable(_ device:)` (~line 423) passes it:

```swift
LayoutEditable(
    deviceId: device.id,
    size: tileSize(device),
    isDragging: draggingId == device.id,
    isResizing: activeResize?.deviceId == device.id,
    dragOffset: dragOffset(for: device.id),
    ...
```

### Windows — `windows/src/ui/styles.css`

Add after the `.is-dragging` rule (~line 2343-2350):

```css
.cc-popover.is-editing .cc-tile.is-resizing {
  animation: none;
}
```

### Windows — `windows/src/ui/app.ts`

The resize state lives in closure-local `resizing` inside `bindLayoutGestures()`, and pausing must
happen without a re-render. Toggle the class directly on the tile element.

In the `pointerdown` handler's resize-handle branch (after `resizing = {...}` is set, ~line 5049):

```ts
if (dev) {
  resizing = { /* ...existing fields... */ };
  handleEl.closest<HTMLElement>("[data-tile-id]")?.classList.add("is-resizing");
}
```

In `clearPreviewTransform(id:animateBack:)` (which already runs on pointerup, pointercancel and
blur), remove it:

```ts
const clearPreviewTransform = (id: string, animateBack: boolean): void => {
  if (previewCleanupTimer !== null) { window.clearTimeout(previewCleanupTimer); previewCleanupTimer = null; }
  const tile = this.root.querySelector<HTMLElement>(`[data-tile-id="${CSS.escape(id)}"]`);
  if (!tile) return;
  tile.classList.remove("is-resizing");
  ... // existing transition/transform logic unchanged
};
```

Because `clearPreviewTransform` looks the tile up by id, it works even after a step re-rendered
the node (the fresh node gets `is-resizing` dropped, which is correct — jiggle resumes there; the
preview continues via inline transform from plan 001).

## Repo conventions to follow

- Windows already pauses motion per-element with an `is-*` class + `animation: none`:
  `.cc-popover.is-editing .cc-tile.is-dragging { animation: none; ... }`
  (`windows/src/ui/styles.css:2343`) — mirror that exact pattern.
- macOS gesture-owned flags flow down through `LayoutEditable`'s let properties
  (`isDragging`, `size`, `dragOffset`) — `isResizing` follows the same path.

## Steps

1. `Sources/MenuBarMijiaApp/DeviceLayout.swift` — add `var isResizing: Bool = false` to `LayoutEditable`; gate `jiggling` on `!isResizing`.
2. `Sources/MenuBarMijiaApp/ControlCenterPanel.swift` — pass `isResizing: activeResize?.deviceId == device.id` in `editable(_:)`.
3. `windows/src/ui/styles.css` — add the `.is-resizing { animation: none; }` rule.
4. `windows/src/ui/app.ts` — add the class on resize pointerdown; remove it in `clearPreviewTransform`.

## Boundaries

- Do NOT change the jiggle amplitude, period, or per-card phase for non-resized cards.
- Do NOT remove the preview scale during resize (that is the gesture feedback; plan 001 owns it).
- Do NOT add an `is-resizing` class via `render()` templates — the pause must work without a
  re-render, since the pointermove path avoids rendering.

## Verification

- **Mechanical**: `swift test --filter longPressOnLightCard` (drag assertions must stay green —
  the jiggle pause must not affect hit testing). `cd windows && npm test && npm run typecheck`
  (the `#115` DOM test asserts `is-dragging` never appears during handle drags; add one assertion
  there that `element(lightSelector).classList.contains("is-resizing")` is `false` after the final
  `pointerup` — i.e. the class is cleaned up).
- **Feel check**: rebuild (`bash scripts/build_app.sh`), enter edit mode:
  - grab a handle: that card freezes its rotation instantly; neighbours keep jiggling;
  - the corner arc stays visually pinned under the pointer while dragging (no ±0.9° wander);
  - release: the card resumes jiggling;
  - press Escape mid-drag (pointercancel path): jiggle resumes.
- **Done when**: the resized card is motion-still except for the tracking preview, on both
  platforms, with all suites green.
