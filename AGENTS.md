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

## Branch virtual-camera (Build 45, 2026-10-29) — RESUME HERE

`main` is the untouched A line (OBS output). All virtual-camera work is on
branch `virtual-camera` (checked out, tree clean). HEAD 3ccca10, pushed;
tags `virtual-camera-works` (Build 42) and `virtual-camera-build-45`.

- State: native virtual camera WORKING and user-verified on camera in
  Zoom + QuickTime (Build 42→45): full card (title/message/picture) at
  720p and 1080p, 1080p capture default with Center Stage off (stable
  wide frame), configurable trigger timing (0.2–2.0 s hold slider),
  two-finger fading brush on cards (1.5 s fade). 199/199 XCTest green
  (unsandboxed), staged app deep-verified.
- Docs: docs/VIRTUAL-CAMERA-SETUP.md (VC-01..07 checklist), README
  Virtual camera + troubleshooting (current), PROGRESS.md tail.
- Next, in order: (1) user runs VC-01..07 checklist; (2) merge
  `virtual-camera` → `main` (ask first); (3) open improvements, all
  optional: per-process HAL refresh so Enable-after-staging works
  without an app restart; motion-gesture triggers — user said WAIT,
  advised against (signing is motion; still-holds only).
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
