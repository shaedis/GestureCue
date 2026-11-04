# AGENTS.md

Project rules for GestureCue. Milestone scope and acceptance criteria live in `SPEC.md`.

## Project

- Name: GestureCue — native macOS SwiftUI app for controlling accessible presentation cards with webcam hand gestures.
- Stack: Swift + SwiftUI, AVFoundation (capture), Apple Vision (`VNDetectHumanHandPoseRequest`), AppKit only for window needs.
- No Electron, React, Python camera services, cloud vision, or third-party dependencies. All camera processing runs locally on-device.

## Commands

- `make build` / `make test` / `make app` (stages `build/GestureCue.app`) / `make run` / `make open` (restarts the staged app) / `make clean` — see `Makefile`.
- Direct: `xcodebuild -scheme GestureCue -destination 'platform=macOS' build` (or `test`).
- Headless/sandboxed shells may need `-derivedDataPath` on a writable path. `make test` needs an unsandboxed shell (macOS power assertion fails sandboxed).

## Layout

- `GestureCue/` — app sources (App, Views, Camera, Vision, Gestures, Cards, Output, Models).
- `GestureCueTests/` — XCTest unit tests.
- `GestureCue.xcodeproj/` — Xcode project (new .swift files must be registered here: PBXBuildFile + PBXFileReference + group child + Sources entry, or the build silently skips them).
- `docs/` — manual test checklists (MT/PA/OB/LIB/REC) + OBS setup; `prompts/` — phase specs; `PROGRESS.md` — round-by-round evidence log.

## Architecture

- Separation of responsibilities: CameraManager, VideoCaptureService, HandPoseDetector, HandGestureDetector, GestureClassifier, GestureStateMachine, GestureActionRouter, VideoCompositor, VideoOutputService, VideoRecorder, CommandWindow, ZoomHandGate, PinchZoomTracker, PresentationCardStore, PresentationLibrary, PresentationImporter, AppViewModel, SwiftUI Views.
- Persist user presentations as JSON in Application Support, seeded once from the bundled samples; card UUIDs stay stable so paint strokes survive relaunch.
- Protocols + dependency injection for classification and routing so gesture logic is testable without a camera.
- Vision and gesture work off the main thread; publish results to the UI on the main actor.
- Keep the design open for future AI-assisted message generation; do not add cloud/AI integrations without a new milestone spec.

## Video pipeline (virtual-camera-ready)

Long-term goal: feed GestureCue's processed video (camera + card overlays) into Zoom, Teams, and other conferencing apps — first via OBS capture of the program monitor, eventually via our own CoreMediaIO camera extension (`VirtualCameraService`).

- One shared `VideoCaptureService` feeds both gesture recognition and video output. Never open a second capture session for output.
- Capture fans out frames to `VideoFrameConsumer`s: `HandGestureDetector` (local Vision analysis) and the program-output chain (`VideoCompositor` → `VideoOutputService`).
- `VideoCompositor` renders camera frames plus positioned card layouts, color toolbar, pointer, and annotation strokes (later: images, prerecorded clips) into reusable pixel buffers. Target 1280×720 @ 30 FPS.
- Central principle: GestureCue turns live webcam video into an interactive visual canvas. Cards, pointer, and annotations live inside the composited video in one shared normalized coordinate space; app panels are controls, not the deliverable canvas.
- `VideoOutputService` isolates destinations behind a protocol. Milestone 1 ships only the in-app program monitor (`SampleBufferDisplayOutput`); a future `VirtualCameraService` (CoreMediaIO DAL extension) plugs into the same seam with no pipeline rewrite.
- Program output must always flow through the compositor so overlays appear in every destination; it must show the processed feed, never a raw passthrough tap.
- Keep capture, analysis, composition, and output independently testable with stub frames (no camera required for unit tests).
- `VideoRecorder` taps the program pipeline and writes user-initiated video-only MP4s (H.264, source timestamps) to Movies/GestureCue. Never record without the user pressing Record.

## Coding

- Swift 6, modern concurrency; leave zero warnings in touched files.
- Accessibility-first UI: large text, clear contrast, visible status indicators, VoiceOver labels, no dependence on sound.
- Gesture geometry must be resolution-independent (normalized landmark space); no rigid pixel thresholds.

## Privacy

- Camera only, with `NSCameraUsageDescription` set. Video is processed live and never stored or uploaded — except user-initiated MP4s from the Record feature, saved locally only. Never request microphone access.
- Handle denied/unavailable/disconnected cameras with clear user guidance; release capture resources on stop.

## Testing

- XCTest covers: gesture classification, confidence thresholds, stabilization, cooldown/debounce, hold-to-fire stillness gating, gesture-to-action mapping, card state transitions, paint interaction, compositing.
- Build with `xcodebuild` and run the tests before finishing. Distinguish automated results from unverified on-camera behavior; never use fake detections to claim real webcam recognition works.
- Hold-to-fire: a gesture fires only after the same pose is held approximately still for the hold duration (~0.5 s). Significant hand or finger motion restarts the hold without re-arming, so rapid waving or signing must never trigger actions. Fingertips are tracked relative to the wrist: whole-hand sway is free, a shaking finger restarts. Tune via state-machine config, never by special-casing gestures.
- Command listening latches: rest state is signing (all hand input ignored). A still open palm held 2 s, the Listen button, or L starts listening; a still fist held 2 s, Stop, or L ends it; 5 idle minutes end it automatically. The program feed shows a corner dot while listening (green, amber in the last idle minute). The arming palm is suppressed until the hand changes so it never fires its own command. Mouse/keyboard actions always work.

## Development workflow

- Follow the phase specifications in prompts/.
- Implement phases in numerical order.
- Reuse existing code before creating new components.
- Build and test after every implementation phase.
- Never report untested functionality as verified.
- Maintain PROGRESS.md with evidence and blockers.
- Preserve working features from previous phases.
- Do not continue past critical failures.
- Require manual verification for webcam and Zoom functionality.
- Keep camera processing local and privacy-preserving.

## Current state (Build 33, 2026-10-28)

- Shipped and user-verified on camera: 8 gestures (palm, fist, thumbs-up,
  thumb-left/right, index/two/three-finger), latching command listening
  (palm arms, fist ends, 5-min idle backstop, corner dot in feed),
  fingertip-stillness holds, pinch zoom, paint mode, presentation catalog
  + PDF/PowerPoint import, OBS output window, MP4 recording.
- Defaults (mapping v5): palm→show, thumbs-up→hide, thumb-right→next,
  thumb-left→previous, three-fingers→expand; fist/index/two-fingers
  unassigned (all occur in sign language).
- Verify: `make test` (169 XCTest, unsandboxed shell) then `make app` +
  `codesign --verify --deep build/GestureCue.app`; launch with `make open`.
  Manual checklists in docs/ (MT/PA/OB/LIB/REC).
- Caveats: thumb left/right directions were derived from code, not
  hardware — user verifies on camera; new .swift files must be registered
  in the .xcodeproj or the build silently skips them. Repo initialized
  2026-10-28; prompts/ + dev-process docs stay local via .gitignore.
- Where to continue: the presenting flow is feature-complete. Open
  options: native virtual camera (heavy; may need a paid Apple signing
  identity), Phase 2 leftovers (low value — Top preset/appearance),
  AI-generated cards (needs product decisions). Otherwise fix frictions
  from real services. Read PROGRESS.md tail for round-by-round evidence.

## Virtual camera (merged to main, Build 45, 2026-10-29) — RESUME HERE

`main` includes the native virtual camera (merge 2f1eb36, tag
`main-build-45`). Branch `virtual-camera` stays alive for continued
work and is currently synced to `main`. Tags `virtual-camera-works`
(Build 42) and `virtual-camera-build-45` mark the verified milestones.

- State: native virtual camera WORKING and user-verified on camera in
  Zoom + QuickTime (Build 42→45): full card (title/message/picture) at
  720p and 1080p, 1080p capture default with Center Stage off (stable
  wide frame), configurable trigger timing (0.2–2.0 s hold slider),
  two-finger fading brush on cards (1.5 s fade). 199/199 XCTest green
  (unsandboxed), staged app deep-verified.
- Docs: docs/VIRTUAL-CAMERA-SETUP.md (VC-01..07 checklist), README
  Virtual camera + troubleshooting (current), PROGRESS.md tail.
- Next, in order: (1) user runs VC-01..07 checklist; (2) open
  improvements, all optional: per-process HAL refresh so
  Enable-after-staging works without an app restart; motion-gesture
  triggers — user said WAIT, advised against (signing is motion;
  still-holds only). Continue feature work on `virtual-camera`,
  merge to `main` when verified (ask first).
- Machine state (user's Mac): extension v3 active with a fresh staging;
  older `waiting to uninstall on reboot` generations are inert and clear
  at the next reboot. User's app: /Applications copy at Build 45.
- If the device ever goes missing again: quit camera clients →
  Uninstall → Enable; panel reads "waiting for the camera device…"
  until frames truly flow. `systemextensionsctl uninstall` is
  SIP-blocked — in-app Uninstall is the only reset path. Pending
  `waiting to uninstall` generations block fresh launches (reboot
  clears); a fresh-staged device invisible to our scan but visible to
  QuickTime/Zoom means stale per-process HAL view → restart the app.
- Branch learnings: extension embeds via absolute
  `$(BUILT_PRODUCTS_DIR)/$(SYSTEM_EXTENSIONS_FOLDER_PATH)` (dstSubfolderSpec
  16 is silently skipped); extension Info.plist must declare bundle
  id/executable/version keys (static plists get no auto-generation); app
  needs CODE_SIGN_ENTITLEMENTS set or the entitlement silently drops;
  Makefile passes -allowProvisioningUpdates; Bundle.main lookups must use
  absolute URLs; bump the build number with every staged fix so stale
  instances are visible in the window title; `CIContext.render(bounds:)`
  selects a source region — never scales, always transform first;
  host-only updates via `make reinstall` + Enable need no reboot and no
  extension version bump (never `make clean` between iterations);
  Center Stage switch is class-level `centerStageControlMode` /
  `isCenterStageEnabled`, restored to `.user` on stop.

## Branch visual-pedagogy (2026-10-29) — ACTIVE WORK HERE

Spec: docs/visual_Pedagocical_generator.md (untracked, user's file).
Goal: AI Visual Education Studio — import educational texts (paste/PDF/
Markdown/TXT/Jupyter-as-data), plan illustrated lessons via Muse Spark,
render artwork via Muse Image, review/edit, save to the existing
Presentation Catalog, present over the existing video/virtual-camera/MP4
pipeline. The spec doc is the authorizing milestone spec for cloud AI
(the standing rule requires one); webcam frames stay local, only
user-approved documents go to Meta, API key in Keychain.

- Reality checks done: Meta Model API is real
  (`https://api.meta.ai/v1`, OpenAI-compatible: `muse-spark-1.3`,
  `muse-image-1.0`; key from dev.meta.ai). App is NOT sandboxed, so no
  network entitlement needed. No prior AI/network code existed.
- Slice 1 DONE (uncommitted): `GestureCue/AI/` (GenerationModels,
  MetaModelClient, CredentialStore) + GenerationTests — settings enums,
  LessonPlan/DiagramSpec Codable, OpenAI-compatible Spark/Image client
  behind HTTPTransport seam, Keychain + in-memory credential stores.
  209/209 green. Registered in pbxproj (...280-288). Live-verified with
  user's key (META_API_KEY in untracked repo-root .env): Spark envelope
  matches parser; ~150+ reasoning tokens precede content (never cap
  max_tokens on plans; UI must show progress); images are b64 WEBP
  (decodable as-is; ignore requested size, got 1600px).
- Slices 2+3 DONE (uncommitted, Build 47 staged): Studio window
  (import/settings/key/approval/progress/drafts/save), generator actor,
  illustration composer, 4-kind diagram renderer, catalog collections.
  231/231 green. Prompt constrains diagram kinds (live-verified).
- Slice 4 = USER manual gate (Build 47 Studio, their key in Keychain):
  MVP-A history + MVP-B fractions per PROGRESS checklist; then commit +
  push + tag (ask). Honest gaps: no visual layout editor (resize/
  reposition), no cross-deck card move/duplicate; PDF import path has no
  fixture test (verify once manually).
- Build 48 FIX (staged): Studio drafts wiped on main-window changes —
  view model now App-owned (survives window switches).
- Build 49 (staged): lesson card fit — bottom side-by-side picture
  layout, message shrink-to-fit, fit-aware prompts (220-char bodies,
  split rule, standalone bodies), Bible/Religious subject, concept kept
  in detail. 236/236 green. User re-verifies incl. Bible passage run.
- Build 50 (staged): deck round-trip — "Edit Existing Deck…" re-imports
  with artwork+prompts; cards persist prompt + raw base image; per-draft
  prompt editing with dirty marker; "Regenerate Changed" refreshes only
  edited prompts; "Refresh Text" re-composes base art free. 240/240.
  User verifies round-trip flow.
- Privacy invariants for this branch: network only after explicit
  per-lesson approval; source treated as data; generated scenes never
  presented as documentary photos; no sign-language instruction without
  qualified review.
- Build 51 (2026-10-30, staged, UNCOMMITTED): hackathon readiness
  verification done — live E2E both MVP scenarios green via temp probe
  (removed; artifacts in /tmp/mvp, key file deleted), 2 fixes
  (diagram band skip + diagramKind round-trip; cancel passthrough),
  244/244 green. Docs: README Studio section, MANUAL-TEST-STUDIO.md
  (ST-01..12), EXTERNAL-REVIEW → Build 51. Resume: user runs ST-01..12
  + VC-01..07 on Build 51, then commit + push + tag (ask).
- Build 52: approval tick resets when source text/title edited
  (ST-02 code-check edge). Build 53 (staged, UNCOMMITTED): card
  titles wrap to 3 lines on narrow panels instead of truncating.
  247/247 green. User gate restarts on Build 53 (ST-01..02 quick
  redo + rest of ST/VC).
- Build 54 (staged, UNCOMMITTED): fix-issues.md — single Studio
  window; New + ask-to-save (dirty tracking, canSave gate, cancel
  race closed); Studio menus list AI decks only (prompt
  provenance). 248/248 green. Split-view parked in
  docs/PENDING-FEATURES.md (awaiting approval). User verifies
  3 fixes + runs gate on Build 54.
- Build 55 (staged, UNCOMMITTED): fix-issues #4 — imports clear stale
  drafts (adopt clears + cancels generation; guarded import confirm
  over unsaved drafts). 248/248. User verifies + runs gate on 55.
- Build 56 (staged, UNCOMMITTED): fix-issues #5 — main-window close
  dismisses Studio, stops recording/output/camera/virtual stream
  (drafts survive in memory; Dock-click reopens). 248/248. User
  verifies + runs gate on 56.
- Build 57 (staged, UNCOMMITTED): faithful presentation splits — new
  Fidelity (PDF/PP → verbatim split prompt, temp 0.1, empty art
  prompts, null diagrams); generator skips image API for prompt-less
  cards; native .pptx/.ppsx text extraction (PptxTextExtractor, no
  deps; Apple one-shot zlib = raw deflate). Live-verified prompt
  compliance 3/3. 256/256. User verifies PP import + faithful run,
  then gate on 57.
- Build 58 (staged, UNCOMMITTED): next_step_1 gate — PPTX security
  caps + tests; strict plan schema + timeout/retry/messages; mode
  picker + fidelity verdicts; zero warnings; HACKATHON.md,
  RELEASE-CHECKLIST.md, gate Part 3. 273/273. New-features parked.
  User runs gate + flows H/F/P on 58, then commit/push/tag (ask).
- Build 59: "Diverse" collection in Studio menu. Build 60 (staged,
  UNCOMMITTED): card "N/M" corner badge on video (new-features #2).
  275/275. Straight-line brush still open. User runs gate on 60.
- Build 61 (staged, UNCOMMITTED): Suggest-collection button (model
  categorises excerpt; new buckets created + persisted; approval
  gated). Live-verified match + new-category paths. 278/278. User
  runs gate on 61.
- Build 62 (staged, UNCOMMITTED): Video + Card side-by-side position
  (whole camera aspect-fit in left tile, card right 40%). 282/282.
  User runs gate on 62.
- Builds 63–71 (committed 3474dc9, tag visual-pedagogy-build-71):
  PP original images reattached (63), PDF original images (64),
  optional AI Instructions (65), save-confirm + auto-close (66),
  adult prose for adults (67), video tile left/right/bottom (68),
  fewer-cards confirmation (69), card-centric panel picker (70),
  per-card regen spinner (71). Full detail in PROGRESS.md.
- Builds 72–76 (committed 854324f, tag visual-pedagogy-build-76,
  merged to main + tag main-build-76): brush shape snapping (72),
  halo over photos (73), window-alive + mouse brush (74), adaptive
  halo (75), mouse brush parked as future feature (76,
  docs/PENDING-FEATURES.md). Gate ST-13/14/15 added; ST-16 parked.
- Builds 77–82 (committed f8a955e, tag visual-pedagogy-build-82,
  merged to main c6cc73a + tag main-build-82): app icon (77), card
  cap 10→30 (78), pinch-zoom toggle (79), brush toggle (80,
  365/365), merged deck menus (81), output labels renamed (82).
- README series (docs-only, no build bump; all merged to main):
  feature rundown, pretty header, ST-15 + VC-01 ticks, showcase-first
  reorder, generation-mode names, Contributors credit. Main keeps
  only setup guides + QA checklists; this branch keeps the full dev
  record (PROGRESS, EXTERNAL-REVIEW, HACKATHON, gate, pending specs).

## Branch visual-pedagogy (Build 82, 2026-11-04) — RESUME HERE

Branch tip 6d973bf, main tip 1707a90 (both pushed; tags
visual-pedagogy-build-82 + main-build-82 on origin). Suite 365/365
green, staged app deep-verified, window title Build 82. User
reports full gate all-run (ST-01..15, VC-01..07, flows H/F/P);
file boxes ticked except VC-05 (open) and ST-16 (parked).

- Verify: `make test` (unsandboxed shell) then `make app` +
  `codesign --verify --deep build/GestureCue.app`; `make reinstall`
  for host-only updates (no reboot, no extension bump).
- Pending: user runs VC-05 + publishes to GitHub (repo
  https://github.com/shaedis/GestureCue); parked: mouse brush
  (ST-16), split-view — specs in docs/PENDING-FEATURES.md, do not
  implement without approval.
- Merge-back rule: future branch→main merges must KEEP main's doc
  deletions (PROGRESS.md, HACKATHON-SUBMISSION.md, EXTERNAL-REVIEW.md,
  HACKATHON.md) — resolve modify/delete conflicts with `git rm`.
- Resume: read this file + PROGRESS.md tail; full build history
  (Builds 46–82) lives in PROGRESS.md, not here.
