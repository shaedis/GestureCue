# GestureCue — Hackathon Record (branch `visual-pedagogy`)

What was designed and built during the hackathon, on top of the
pre-existing gesture + virtual-camera foundation from `main`
(Build 45: 8 gestures, command latch, paint/brush, catalog, OBS
output, MP4 recording, native virtual camera).

## AI Visual Education Studio (Builds 46–58)

A Meta AI-powered lesson generator inside the native macOS app:

- **Studio window** — source import (paste, PDF, PowerPoint, Markdown,
  TXT, notebooks, AI decks), lesson settings, Keychain key entry,
  per-source approval gate, progress + cancel, editable drafts, save
  to catalog collections (Builds 46–47).
- **Two generation modes** — Visual Educational (creative illustrated
  lessons: Muse Spark plans, Muse Image art, deterministic local
  diagrams for exact content) and Faithful Presentation (verbatim
  PDF/PowerPoint splits, no new text/art, measured per-card fidelity
  shown in review). Explicit user choice with kind-based defaults
  (Builds 49, 57).
- **Meta API client** — OpenAI-compatible `muse-spark-1.3` /
  `muse-image-1.0` behind mockable transport; strict JSON Schema
  plan enforcement (live-verified), explicit timeouts, one retry on
  429/5xx, per-status error messages, approval + Keychain
  protections (Builds 46, 51, 57).
- **Native PowerPoint import** — dependency-free zip + slide-XML
  text extractor with security caps (entry/size/total limits,
  DOCTYPE rejection) and regression tests (Builds 57–58).
- **Deck round-trip** — re-import any AI deck for adjustment;
  artwork + prompts travel along; per-card edited markers;
  regenerate-changed-only; free text refresh; diagrams survive
  re-import without the title band (Builds 50–51).
- **Workspace integrity** — New + ask-to-save, guarded imports over
  unsaved drafts, stale-draft clearing, AI-only deck menus, single
  Studio window, main-close shuts capture/output cleanly (Builds
  54–56).
- **Subjects incl. Bible/Religious** with a verse word-for-word rule;
  Swedish + English lesson language support (Build 49).

## Studio polish + output legibility (Builds 59–76)

- **Catalog UX** — "Diverse" collection, model-suggested collections
  (approval-gated, persisted), card N/M badge on video, per-card
  regeneration spinner, fewer-cards confirmation, save flashes green
  then closes (Builds 59–61, 66, 69, 71).
- **Original-image reattachment** — PowerPoint slide rels and PDF
  XObjects feed the author's own pictures back onto generated cards
  (Builds 63–64).
- **Prompt control** — optional AI Instructions (blank = identical
  default; provided = labelled, subordinated), adult prose for adult
  audiences (Builds 65, 67).
- **Video + Card placement** — card panel Left/Right/Bottom with the
  whole camera aspect-fit opposite (Builds 62, 68, 70).
- **Brush legibility** — shape snapping on release (lines/ellipses,
  no ML), per-segment adaptive halo over photos and white diagrams,
  paint activity keeps the command window alive (Builds 72–75).
- Mouse brush implemented then parked as a future feature (Builds
  74/76; see `docs/PENDING-FEATURES.md`).

## Verification produced

- 363 XCTest tests (from 179), one known minor pre-existing warning;
  strict-schema and faithful-prompt behavior proven against the live
  API; composited 720p + small-tile readability reviewed from real
  pipeline output; encoder round-trips (H.264, downscale, low
  bitrate) used to diagnose brush legibility.
- Manual gates run by the user: ST-01..14 + flows H/F/P checked,
  VC-02/03/04/06/07 checked; outstanding: ST-15, VC-01/05 (ST-16
  parked with the mouse brush). Records live in
  `docs/USER-VERIFICATION-GATE.md`.
- Review pack for judges: `HACKATHON-SUBMISSION.md` (one page),
  `docs/EXTERNAL-REVIEW.md` (adversarial brief),
  `docs/DEMO-SCRIPT.md` (3-minute demo), this file.

## Deliberately not built

Motion-gesture triggers (signing is motion — still-holds only),
visual layout editor, cross-deck move/duplicate, split-view layout
and mouse brush (both parked in `docs/PENDING-FEATURES.md`), Phase 2
leftovers (Top preset, appearance).
