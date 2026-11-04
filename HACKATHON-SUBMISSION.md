# GestureCue — Hackathon Submission (Build 82, merged to `main`)

## The problem

A presenter who signs on a video call while showing slides forces Deaf
viewers to split attention between interpreter, captions, screen share,
and speaker — cues get missed. And turning a hard textbook page, article,
or Bible passage into clear visual teaching cards takes hours of design
work most presenters don't have.

## What GestureCue does

GestureCue is a native macOS app with two halves:

1. **AI Visual Education Studio** — paste text or import a PDF/PowerPoint;
   Meta AI turns it into illustrated lesson cards (Muse Spark plans the
   storyboard, Muse Image illustrates it, exact content like fractions
   renders as precise local diagrams). Review, edit, and save to the
   catalog. Importing an existing deck splits it faithfully — your words
   verbatim, your pictures kept, no AI cost for images.
2. **Gesture-driven video cards** — the lesson appears *inside* the
   presenter's own webcam feed in Zoom/Teams via a native virtual camera.
   Hand gestures show, hide, and advance cards; a two-finger brush
   highlights text and fades away. Hands are ignored by default so normal
   signing never triggers anything — only an explicit 2-second palm hold
   (or button/key) opens a command window.

## Meta integration

- **Muse Spark** (`muse-spark-1.3`) for storyboard planning with a strict
  JSON Schema the app enforces, plus adult-prose and subject rules.
- **Muse Image** (`muse-image-1.0`) for per-card illustrations, composed
  locally with titles and labels.
- Deterministic on-device diagrams for exact proportions and equations.
- Key stored in the macOS Keychain; per-lesson approval gates every send;
  only approved source text and prompts leave the Mac — webcam frames never do.

## Privacy

Camera only, processed live on-device, never stored or uploaded — except
MP4s the user explicitly records (saved locally) and approved lesson
sources sent to the Meta API. No microphone, no analytics, no tracking.

## Verification snapshot

- **365/365 automated tests green** (gestures, paint/brush, compositing,
  virtual camera, AI client/import/generation, deck round-trip).
- **User-verified on camera + Zoom:** gestures, listening latch, paint,
  brush shapes and legibility over photos/diagrams, Zoom feed, MP4
  recording, full Studio→catalog→Zoom flows for history, fractions,
  and faithful PowerPoint import (ST-01..15, VC-01..07, flows H/F/P).
  ST-16 mouse brush is parked as a future feature.
- **Manual gate fully run** — no outstanding checks.
- Adversarial review brief: `docs/EXTERNAL-REVIEW.md`. Manual evidence:
  `docs/USER-VERIFICATION-GATE.md`. Three-minute demo: `docs/DEMO-SCRIPT.md`.

## Run it

```sh
make test   # 365 XCTest tests (unsandboxed shell)
make app    # stage build/GestureCue.app
```

Copy the staged app to `/Applications`, open it (title shows the build),
press Start Camera, and — for the Studio — paste a Meta API key (Keychain).
Pick **GestureCue Camera** in Zoom. Details: `README.md`.

## Built during the hackathon

Everything past `main` at `main-build-45` (now merged to `main`):
the AI Studio end to end (Builds 46–71), brush shape-snapping (72),
adaptive brush legibility halo (73/75), activity-aware command window
(74), app icon, card cap 30, brush/zoom toggles, menu + label polish
(77–82). See `docs/HACKATHON.md` for the build-by-build record.
Foundation (gestures, latch, paint, virtual camera) predates the
hackathon on `main`.
