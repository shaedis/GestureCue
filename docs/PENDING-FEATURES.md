# Pending features (awaiting user approval)

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
