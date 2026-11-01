# 001 — Continuous resize preview across steps (kill the per-step scale snap)

- **Status**: TODO
- **Commit**: baf7098
- **Severity**: HIGH
- **Category**: Interruptibility / Physicality & origin
- **Estimated scope**: 4 files (2 Swift, 2 TS), ~40 lines

## Problem

While dragging the corner handle, the card scales toward the drag (tracking preview). But the
instant a 30pt step fires, the preview snaps back to scale 1 while the layout spring simultaneously
animates the real size change. The card visibly shrinks ~3–5% and re-grows every time it steps —
the single biggest contributor to the "not smooth" feel.

macOS — the preview is hard-gated on `didStep`, so it returns 1 the moment a step fires
(`Sources/MenuBarMijiaApp/ControlCenterPanel.swift:439-442`):

```swift
private func resizePreviewScale(for device: SmartDevice) -> CGFloat {
    guard let resize = activeResize, resize.deviceId == device.id, !resize.didStep, !reduceMotion else { return 1 }
    return TileResizeGestureMath.previewScale(startSize: resize.startSize, translation: activeResizeTranslation)
}
```

Windows — after a step the code re-renders and early-returns, so the new tile node never gets an
inline transform (`windows/src/ui/app.ts:5084-5090`):

```ts
if (next !== this.tileSize(dev)) {
  resizing.didStep = true;
  this.layout.tileSizes[scopedKey(this.pageKey, dev.id)] = next;
  this.saveLayout();
  this.render();
  return;   // <-- preview transform dropped; new node starts at scale 1
}
```

The tracking math itself also restarts from zero each step
(`Sources/MenuBarMijiaApp/DeviceLayout.swift:93-104`):

```swift
public static func previewScale(startSize: TileSize, translation: CGSize, threshold: CGFloat = stepThreshold) -> CGFloat {
    let distance = hypot(translation.width, translation.height)
    guard distance > 1 else { return 1 }
    let progress = min(distance / threshold, 1)
    ...
}
```

## Target

Progress is measured **cumulatively**: `progress = distance/threshold − stepsCrossed`, clamped to
0…1. The preview then stays continuous through every step (at the moment of a step it is exactly
1, because the real layout takes over) and only resets when the gesture ends. Both platforms
compute `stepsCrossed` identically as the ordinal distance between the start size and the current
size (`half`=0, `full`=1, `panel`=2).

### macOS

`Sources/MenuBarMijiaApp/DeviceLayout.swift` — replace the `previewScale` signature and body with:

```swift
/// Corner-anchored tracking preview while the drag has not crossed a step yet:
/// growing outward scales up to +5%, pushing inward rubberbands down to −4%.
/// Progress is cumulative across steps: `distance/threshold − stepsBetween(start, current)`,
/// so the preview never snaps when a step fires — it is exactly 1 at the crossing moment.
public static func previewScale(
    startSize: TileSize,
    currentSize: TileSize,
    translation: CGSize,
    threshold: CGFloat = stepThreshold
) -> CGFloat {
    let distance = hypot(translation.width, translation.height)
    guard distance > 1 else { return 1 }
    let stepsCrossed = CGFloat(abs(stepsBetween(startSize, currentSize)))
    let progress = min(max(distance / threshold - stepsCrossed, 0), 1)
    let outward: Bool
    switch startSize {
    case .half: outward = translation.width > 0 || translation.height > 0
    case .panel: outward = translation.width < 0 || translation.height < 0
    default: outward = (abs(translation.width) >= abs(translation.height) ? translation.width : translation.height) >= 0
    }
    return 1 + (outward ? 0.05 : -0.04) * progress
}

/// Ordinal distance between two concrete sizes in the half → full → panel ladder (-1 for auto).
public static func stepsBetween(_ a: TileSize, _ b: TileSize) -> Int {
    let ladder: [TileSize] = [.half, .full, .panel]
    guard let ia = ladder.firstIndex(of: a), let ib = ladder.firstIndex(of: b) else { return 0 }
    return ib - ia
}
```

Note: `private static let orderedSizes` already exists in `TileResizeGestureMath`; the new
`stepsBetween` may reuse it instead of declaring a local `ladder` — either way keep exactly one
ladder definition in the enum.

`Sources/MenuBarMijiaApp/ControlCenterPanel.swift:439-442` — drop the `didStep` gate and pass the
current size:

```swift
private func resizePreviewScale(for device: SmartDevice) -> CGFloat {
    guard let resize = activeResize, resize.deviceId == device.id, !reduceMotion else { return 1 }
    return TileResizeGestureMath.previewScale(
        startSize: resize.startSize,
        currentSize: tileSize(device),
        translation: activeResizeTranslation
    )
}
```

### Windows

`windows/src/ui/panelPrefs.ts` — same signature change on `resizePreviewScale`:

```ts
/** Ordinal distance between two concrete sizes in the half → full → panel ladder (auto = 0). */
export function stepsBetween(a: TileSize, b: TileSize): number {
  const ladder: Array<Exclude<TileSize, "auto">> = ["half", "full", "panel"];
  const ia = ladder.indexOf(a as Exclude<TileSize, "auto">);
  const ib = ladder.indexOf(b as Exclude<TileSize, "auto">);
  return ia < 0 || ib < 0 ? 0 : ib - ia;
}

/** Corner-anchored tracking preview; cumulative progress so steps never snap the preview. */
export function resizePreviewScale(
  startSize: TileSize,
  currentSize: TileSize,
  translation: TileResizeTranslation,
  threshold = RESIZE_STEP_THRESHOLD,
): number {
  const distance = Math.hypot(translation.width, translation.height);
  if (distance <= 1) return 1;
  const stepsCrossed = Math.abs(stepsBetween(startSize, currentSize));
  const progress = Math.min(Math.max(distance / threshold - stepsCrossed, 0), 1);
  const outward =
    startSize === "half"
      ? translation.width > 0 || translation.height > 0
      : startSize === "panel"
        ? translation.width < 0 || translation.height < 0
        : (Math.abs(translation.width) >= Math.abs(translation.height) ? translation.width : translation.height) >= 0;
  return 1 + (outward ? 0.05 : -0.04) * progress;
}
```

(`ORDERED_CONCRETE_TILE_SIZES` already exists in this module; `stepsBetween` may reuse it instead
of a local `ladder` — keep exactly one ladder.)

`windows/src/ui/app.ts` — in the `pointermove` resize branch, remove the early `return` after
`this.render()` and write the preview transform **after** the render, re-querying the fresh node:

```ts
const dev = this.devices.find((d) => d.id === resizing?.id);
if (!dev) return;
const next = targetSize(
  resizing.startSize,
  { width: dx, height: dy },
  this.settings.isCompactGridMode,
);
if (next !== this.tileSize(dev)) {
  resizing.didStep = true;
  this.layout.tileSizes[scopedKey(this.pageKey, dev.id)] = next;
  this.saveLayout();
  this.render();
  // No early return: fall through so the fresh node keeps the continuous preview.
}
if (!window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
  const tile = this.root.querySelector<HTMLElement>(`[data-tile-id="${CSS.escape(resizing.id)}"]`);
  if (tile) {
    const scale = resizePreviewScale(resizing.startSize, this.tileSize(dev), { width: dx, height: dy });
    tile.style.transformOrigin = "bottom right";
    tile.style.transform = scale === 1 ? "" : `scale(${scale.toFixed(4)})`;
  }
}
return;
```

(The old nested `if (tile && ...)` block below the step commit is replaced by the block above.)

## Repo conventions to follow

- Pure layout math lives in `TileResizeGestureMath` (Swift, `Sources/MenuBarMijiaApp/DeviceLayout.swift`)
  and `windows/src/ui/panelPrefs.ts`; the doc comments on both state they must stay semantically
  identical — update both sides in the same commit, every time.
- Exemplar of a pure, tested helper in this pair: `targetSize` (Swift :34-52, TS :119-131).

## Steps

1. Swift: add `stepsBetween` + rewrite `previewScale` in `Sources/MenuBarMijiaApp/DeviceLayout.swift` (keep the doc comment, new signature).
2. Swift: update `resizePreviewScale(for:)` in `Sources/MenuBarMijiaApp/ControlCenterPanel.swift:439-442` (remove `!resize.didStep`, pass `currentSize: tileSize(device)`).
3. TS: add `stepsBetween` + rewrite `resizePreviewScale` in `windows/src/ui/panelPrefs.ts`.
4. TS: update the `pointermove` resize branch in `windows/src/ui/app.ts` per the Target block (remove early return; write preview after render with `currentSize`).
5. TS: update the `pointerup` flick branch? No — it commits via `targetSize` only; unchanged.
6. Update tests (see Verification) — the old `previewScale(startSize:translation:)` call sites break otherwise.

## Boundaries

- Do NOT touch the threshold value (30), the flick projection, haptics, or `setTileSize`'s spring.
- Do NOT change the handle's visual size/opacity (plan 003 owns that).
- Do NOT restructure the gesture wiring between `LayoutEditable` and `ControlCenterPanel` (plan 005 owns that).
- If `previewScale` callers other than `ControlCenterPanel.swift:441` and `app.ts` exist, STOP and report.

## Verification

- **Mechanical**: `cd windows && npm test && npm run typecheck` — all green. Update
  `windows/tests/panelPrefs.test.ts` "preview scale" test to the new signature, adding:
  `resizePreviewScale("half", "full", { width: 45, height: 0 })` ≈ 1.025 (2nd step in progress,
  45/30 − 1 = 0.5) and `resizePreviewScale("half", "full", { width: 31, height: 0 })` === 1
  (exactly at the crossing). Update the Swift mirror test
  `Tests/MenuBarMijiaAppTests/MenuBarPanelControllerTests.swift` `tileResizeGestureMathPreviewScale`
  the same way, plus `#expect(TileResizeGestureMath.stepsBetween(.half, .panel) == 2)`.
  Then `swift test --filter tileResizeGestureMath` and `swift test --filter longPressOnLightCard`.
- **Feel check**: rebuild (`bash scripts/build_app.sh`), enter edit mode, drag a half card's handle
  slowly right through full into panel territory:
  - the card must grow continuously — no visible shrink/regrow at each step boundary;
  - at the exact crossing moment the card is at scale 1 while the layout spring animates;
  - reverse direction mid-drag: the preview rubberbands back without jumps.
- **Done when**: dragging across two steps in one gesture shows one continuous motion, and both
  test suites pass.
