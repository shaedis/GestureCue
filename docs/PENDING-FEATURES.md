# Pending features (awaiting user approval)

## Mouse brush on the program monitor — PARKED (implemented, unverified)

Built 2026-10-30 (Build 74, user request), parked Build 76 by user
decision before on-site verification: no crosshair appears over the
program monitor, so whether drags miss the view (wrong surface) or
events never arrive (event-path bug) is undetermined.

**Idea:** press-drag-release with the mouse on the program monitor
paints fading brush strokes as an alternative to the two-finger
brush — same fade, halo, and shape-snapping; explicit UI input, so
it works even while detection is paused, like buttons and keys.

**State in tree (inert, all tested):** `FingerPaintController`
mouse API (down/move/up, own fading array merged at push, snap on
release, cleared on card switch), `MouseBrushMonitorView` (mouse
tracking, crosshair cursor, aspect-fill view→paint mapping with
mirror + clamp), view-model wiring. 14 tests green (lifecycle,
hand coexistence, paused independence, mapping). The on-screen
help text was removed so the app advertises nothing unverified.

**Shape when reactivated:**

- Reproduce on-site: hover the Program Output monitor (bottom of the
  Camera panel, card composited over video) — crosshair must appear.
- If yes but no paint: trace the view→controller→compositor path.
- If no crosshair on the right surface: debug cursor rects / event
  routing in `MouseBrushMonitorView` (`GestureCue/Views/ProgramOutputView.swift`).
- Restore the help text + a11y label in `CameraPanelView`, unpark
  gate item ST-16, verify strokes land under the cursor and show in
  the Zoom tile.

## Split-view presentation layout — AWAITING APPROVAL

Proposed 2026-10-30 (user request, parked before implementation).

**Idea:** present two tiles at once instead of one card — the
illustration as a left/right side tile plus the texts as a bottom band,
so picture and wording each get full room. Intended as more
pedagogical for visual lessons (diagrams, Bible scenes).

**Assessment:** good as an *optional* per-deck layout, not the default.
A side tile + bottom band shrinks the free signer area to roughly the
top-left 64% × 70% of the frame (vs 100% × 70% for bottom cards today),
demoting the signer who is the app's main subject. Picture-heavy
lessons can opt in; signing-heavy ones stay single-card.

**Shape when approved:**

- New `Split` position beside Bottom/Left/Right (per-deck setting,
  default unchanged): picture tile in the right column (upper ~65%),
  text band along the bottom-left, no overlap.
- No generation/model changes needed: text + art already exist
  separately per card — purely a compositor layout.
- Open interaction questions: paint clips to both tiles; pinch-zoom
  targets the picture tile; Expand shows text + picture side by side
  fullscreen; optional squarer art requests later (aspect-fit is
  acceptable today).
