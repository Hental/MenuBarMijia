# 005 — Localize resize tracking state so macOS stops re-rendering the panel every pointermove

- **Status**: TODO
- **Commit**: baf7098
- **Severity**: MEDIUM
- **Category**: Performance
- **Estimated scope**: 2 files (Swift), ~50 lines net

## Problem

On macOS, every `pointermove` during a handle drag writes parent-level `@State`, re-evaluating the
entire `ControlCenterPanel` body (~2000 lines of view code, every section, every card) at pointer
frequency (up to 120Hz on ProMotion):

`Sources/MenuBarMijiaApp/ControlCenterPanel.swift:766-773` (`updateResize`):

```swift
let now = Date.timeIntervalSinceReferenceDate
current.samples.append(TileResizeGestureMath.ResizeSample(offset: translation, time: now))
current.samples = current.samples.filter { now - $0.time <= 0.12 }
activeResize = current
activeResizeTranslation = translation   // <-- parent @State, read by resizePreviewScale(for:)
```

`activeResizeTranslation` is consumed only by `resizePreviewScale(for:)`
(`ControlCenterPanel.swift:439-442`), which is only used by the one card being resized — so 99% of
the per-frame work is wasted diffing. The samples array has the same problem: it is gesture-local
data parked in parent state.

QuotaKeeper solves the identical problem by keeping gesture values in motion values / direct style
writes and only committing state at step boundaries ("Real dimensions keep text crisp; only the
active card needs layout during resize").

## Target

The per-pointermove data (preview scale + velocity samples) lives as **local `@State` inside
`LayoutEditable`**. The parent keeps only:

- `activeResize` (device id + start size + didStep) — still needed by `tileDragGesture`'s
  guard (`ControlCenterPanel.swift:679-686`) and `resizeHandleCardId`, but it changes only on
  gesture start / step commit / gesture end, NOT per pointermove;
- step commits via `setTileSize`.

`activeResizeTranslation` is deleted from the parent entirely. `LayoutEditable`'s own
`DragGesture` handlers update the local state directly; the parent callbacks are narrowed to:

```swift
var onBeginResize: () -> Void = {}
var onResizeStep: (CGSize) -> Void = { _ in }          // was onResizeDrag; called ONLY when a step fires
var onEndResize: (CGSize, [TileResizeGestureMath.ResizeSample]) -> Void = { _, _ in }
```

### `Sources/MenuBarMijiaApp/DeviceLayout.swift` — `LayoutEditable`

Add local state and rewire the gesture:

```swift
struct LayoutEditable: ViewModifier {
    ...
    @State private var previewScale: CGFloat = 1
    @State private var resizeSamples: [TileResizeGestureMath.ResizeSample] = []
    ...
    func body(content: Content) -> some View {
        ZStack(alignment: .bottomTrailing) {
            jiggling(content.allowsHitTesting(!editing))
                .scaleEffect(isDragging ? 1.05 : 1)
                .scaleEffect(previewScale, anchor: .bottomTrailing)   // local state now
                .shadowIf(isDragging, color: .black.opacity(0.3), radius: 12, y: 6)
            ...
                    .highPriorityGesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named(TileSpace.name))
                            .onChanged { value in
                                guard !reduceMotion else { return }
                                let now = Date.timeIntervalSinceReferenceDate
                                resizeSamples.append(TileResizeGestureMath.ResizeSample(offset: value.translation, time: now))
                                resizeSamples = resizeSamples.filter { now - $0.time <= 0.12 }
                                previewScale = TileResizeGestureMath.previewScale(
                                    startSize: size == .auto ? (isCompactGrid ? .half : .full) : size,
                                    currentSize: size,   // see step 3 note
                                    translation: value.translation
                                )
                                onResizeDrag(value.translation)   // parent computes steps; does NOT store translation
                            }
                            .onEnded { value in
                                previewScale = 1
                                let samples = resizeSamples
                                resizeSamples = []
                                onEndResize(value.translation, samples)
                            }
                    )
```

LayoutEditable needs `isCompactGrid` to resolve `.auto` — the parent already resolves `size` to a
concrete size before passing it in (`ControlCenterPanel.swift:424` passes `tileSize(device)` which
resolves auto), so inside the gesture `size` is already concrete: use `size` directly as
`startSize`/`currentSize` and drop the auto-resolution branch shown above.

The parent still runs the *step* logic per move (`targetSize(...)` compare) — but it no longer
writes any per-move state; it only writes when the size actually changes. In
`ControlCenterPanel.updateResize` delete the samples/translation writes:

```swift
private func updateResize(_ deviceId: String, translation: CGSize) {
    guard let current = activeResize,
          current.deviceId == deviceId,
          let device = store.devices.first(where: { $0.id == deviceId }) else { return }
    let target = TileResizeGestureMath.targetSize(
        startSize: current.startSize,
        translation: translation,
        isCompactGrid: store.isCompactGridMode
    )
    if target != tileSize(device) {
        activeResize?.didStep = true
        setTileSize(target, for: device, playHaptic: true)
    }
}
```

`beginResizeIfNeeded` stops initialising translation/samples:

```swift
activeResize = ActiveTileResize(deviceId: deviceId, startSize: tileSize(device), didStep: false, samples: [])
```

(`ActiveTileResize.samples` can be deleted from the struct — samples live in `LayoutEditable` now.)

`endResize(_ deviceId:translation:samples:)` gains the samples parameter, keeps the flick
projection unchanged, and `resizePreviewScale(for:)` is deleted from the parent
(`ControlCenterPanel.swift:437-442`), along with the `@State activeResizeTranslation`
(`ControlCenterPanel.swift:14`).

`editable(_ device:)` stops passing `resizePreviewScale:`; `LayoutEditable` drops that property
(its local `previewScale` replaces it).

## Repo conventions to follow

- Gesture-scoped state belongs to the gesture's view: `DeviceCardView` already keeps
  `@State dragBrightness` for its own drag feedback (`Sources/MenuBarMijiaApp/DeviceCardView.swift:23`)
  instead of parking it in the panel.
- Parent state is reserved for data multiple views or the container gesture need
  (`draggingId`, `dragLocation` drive reorder + offsets across cards).

## Steps

1. `Sources/MenuBarMijiaApp/DeviceLayout.swift` — add `@State previewScale` + `@State resizeSamples` to `LayoutEditable`; delete the `resizePreviewScale` property; update the gesture handlers per the Target block; keep `.highPriorityGesture` structure identical otherwise.
2. Same file — remove `samples` from `ActiveTileResize` (leave `deviceId`, `startSize`, `didStep`).
3. `Sources/MenuBarMijiaApp/ControlCenterPanel.swift` — delete `@State activeResizeTranslation` and `resizePreviewScale(for:)`; stop passing `resizePreviewScale:` in `editable(_:)`; strip samples/translation writes from `updateResize`/`beginResizeIfNeeded`; extend `endResize` to `(deviceId:translation:samples:)` and use the passed samples for the flick projection.
4. Update the two `onEndResize` call paths — they are closures created in `editable(_ device:)`; only the closure signature changes there. `tileDragGesture.onEnded` calls `endResize(resizingId, translation: d.translation)` directly — pass `[]` only if that path has no samples (it cannot have any: the handle's own gesture owns sampling; the container gesture path only fires if the handle gesture was cancelled, in which case flick projection on empty samples returns `.zero` — correct).

## Boundaries

- Do NOT move `activeResize` itself into `LayoutEditable` — `tileDragGesture`
  (`ControlCenterPanel.swift:679-686`) and `resizeHandleCardId` depend on it for gesture isolation.
- Do NOT change Windows in this plan (Windows already writes style directly without re-renders).
- Do NOT change the math (`previewScale`, `targetSize`, flick) — state ownership only.
- If `resizePreviewScale(for:)` or `activeResizeTranslation` have other consumers after step 3,
  STOP and report.

## Verification

- **Mechanical**: `swift test --filter longPressOnLightCard` — the real-window test drives
  mouse-down/move/up through the same gesture chain; all size assertions must stay green.
  Full `swift test --skip SnapshotTests` green.
- **Feel check**: rebuild (`bash scripts/build_app.sh`):
  - in edit mode, drag a handle across two steps with Instruments' SwiftUI view or simply observe:
    motion stays as smooth as before (this refactor must be feel-neutral — it is a perf fix);
  - flick release still advances one step (samples still flow to `endResize`);
  - tap still cycles; reorder drag by the card body still works (the `tileDragGesture` guard is
    untouched).
- **Done when**: no per-pointermove parent state writes remain (grep
  `activeResizeTranslation` → zero hits), all suites green, feel unchanged or better.
