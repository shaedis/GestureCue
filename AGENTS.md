# AGENTS.md

Project rules for GestureCue. Milestone scope and acceptance criteria live in `SPEC.md`.

## Project

- Name: GestureCue — native macOS SwiftUI app. Presenters control accessible presentation cards composited into their webcam feed using hand gestures; an AI Visual Education Studio generates illustrated lesson decks from source texts.
- Stack: Swift + SwiftUI, AVFoundation (capture), Apple Vision (`VNDetectHumanHandPoseRequest`), AppKit only for window needs. Meta Model API (Muse Spark + Muse Image) for Studio generation only.
- No Electron, React, Python camera services, or third-party dependencies. All camera processing runs locally on-device.

## Commands

- `make build` / `make test` / `make app` (stages `build/GestureCue.app`) / `make run` / `make open` (restarts the staged app) / `make reinstall` (restage + replace /Applications copy) / `make clean` — see `Makefile`.
- Direct: `xcodebuild -scheme GestureCue -destination 'platform=macOS' build` (or `test`).
- Headless/sandboxed shells may need `-derivedDataPath` on a writable path. `make test` needs an unsandboxed shell (macOS power assertion fails sandboxed).

## Layout

- `GestureCue/` — app sources (App, Views, Camera, Gestures, Cards, Output, Models, AI, ViewModels).
- `GestureCue/Assets.xcassets/` — app icon set.
- `GestureCueTests/` — XCTest unit tests.
- `GestureCue.xcodeproj/` — Xcode project (new .swift files AND asset catalogs must be registered here: PBXBuildFile + PBXFileReference + group child + Sources/Resources entry, or the build silently skips them).
- `docs/` — setup guides (OBS, virtual camera) + runnable QA checklists. Process docs (PROGRESS log, review briefs, fix logs, next-step notes) live on working branches, not on `main`.

## Architecture

- Separation of responsibilities: CameraManager, VideoCaptureService, HandPoseDetector, HandGestureDetector, GestureClassifier, GestureStateMachine, GestureActionRouter, CardOverlayCompositor, VideoOutputService, VideoRecorder, VirtualCameraService, CommandWindow, ZoomHandGate, PinchZoomTracker, FingerPaintController, BrushShapeClassifier, PresentationCardStore, PresentationLibrary, PresentationImporter, MetaModelClient, LessonGenerator, IllustrationComposer, StudioViewModel, AppViewModel, SwiftUI Views.
- Persist user presentations as JSON in Application Support, seeded once from the bundled samples; card UUIDs stay stable so paint strokes survive relaunch.
- Protocols + dependency injection for classification and routing so gesture logic is testable without a camera.
- Vision and gesture work off the main thread; publish results to the UI on the main actor.
- New cloud/AI integrations need a milestone spec; the Studio is the only networked surface.

## Video pipeline

GestureCue turns live webcam video into an interactive visual canvas: cards, pointer, and annotations live inside the composited feed in one shared normalized coordinate space; app panels are controls, not the deliverable canvas.

- One shared `VideoCaptureService` (720p/1080p selectable, 1080p default) feeds both gesture recognition and video output. Never open a second capture session for output.
- Capture fans out frames to `VideoFrameConsumer`s: `HandGestureDetector` (local Vision analysis) and the program-output chain (`CardOverlayCompositor` → `VideoOutputService`).
- `VideoCompositor` renders camera frames plus positioned card layouts, pointer, and paint/brush strokes (with the adaptive legibility halo) into reusable pixel buffers. Target 1280×720 @ 30 FPS.
- `VideoOutputService` isolates destinations behind a protocol: in-app program monitor, fullscreen window (OBS capture fallback), user-initiated MP4 recorder (H.264, video-only, Movies/GestureCue), and the native CoreMediaIO virtual camera (`GestureCue Camera`, 720p) for Zoom/Teams.
- Program output must always flow through the compositor so overlays appear in every destination; it must show the processed feed, never a raw passthrough tap.
- Keep capture, analysis, composition, and output independently testable with stub frames (no camera required for unit tests).

## Coding

- Swift 6, modern concurrency; leave zero warnings in touched files.
- Accessibility-first UI: large text, clear contrast, visible status indicators, VoiceOver labels, no dependence on sound.
- Gesture geometry must be resolution-independent (normalized landmark space); no rigid pixel thresholds.

## Privacy

- Camera only, with `NSCameraUsageDescription` set. Video is processed live and never stored or uploaded — except user-initiated MP4s, saved locally only. Never request microphone access.
- The Studio sends only user-approved source text and illustration prompts to the Meta Model API (key in Keychain, per-lesson approval gate). Webcam frames never leave the Mac.
- Handle denied/unavailable/disconnected cameras with clear user guidance; release capture resources on stop.

## Testing

- XCTest covers: gesture classification, confidence thresholds, stabilization, cooldown/debounce, hold-to-fire stillness gating, gesture-to-action mapping, card state transitions, paint/brush interaction (shape-snapping, halo, mapping), compositing, program pipeline, MP4 recording, virtual-camera service, AI client/import/generation/extraction, deck round-trip.
- Build with `xcodebuild` and run the tests before finishing. Distinguish automated results from unverified on-camera behavior; never use fake detections to claim real webcam recognition works.
- Hold-to-fire: a gesture fires only after the same pose is held approximately still for the hold duration (~0.5 s). Significant hand or finger motion restarts the hold without re-arming, so rapid waving or signing must never trigger actions. Fingertips are tracked relative to the wrist: whole-hand sway is free, a shaking finger restarts. Tune via state-machine config, never by special-casing gestures.
- Command listening latches: rest state is signing (all hand input ignored). A still open palm held 2 s, the Listen button, or L starts listening; a still fist held 2 s, Stop, or L ends it; 5 idle minutes end it automatically, refreshed by any user activity (commands, zoom, paint/brush). The program feed shows a corner dot while listening (green, amber in the last idle minute). The arming palm is suppressed until the hand changes so it never fires its own command. Pinch zoom and the two-finger brush each have a persisted on/off toggle; both default on. Mouse/keyboard actions always work.

## Development workflow

- The phase plan is done; new work ships as small staged builds: implement, build, test, stage, verify on camera where applicable.
- Reuse existing code before creating new components. Preserve working features. Do not continue past critical failures.
- Never report untested functionality as verified. Require manual verification for webcam and Zoom functionality.
- Record progress and evidence on the working branch. Merge to `main` when verified (ask first).
- Keep camera processing local and privacy-preserving.

## Current state (Build 82, 2026-10-31)

- `main` is the published line (merge c6cc73a, tags `main-build-82` + `visual-pedagogy-build-82`): 8 gestures (mapping v5), latching listening with activity refresh, paint mode, fading brush (shape-snapping, adaptive halo, on/off toggles for brush and pinch zoom), presentation catalog + PDF/PowerPoint import, AI Visual Education Studio (Spark planning, Muse Image art, local diagrams, faithful mode with original-image reattachment), OBS window, MP4 recording, native virtual camera.
- Verified: 365/365 XCTest green; user reports the full manual gate all-run (ST-01..15, VC-01..07, flows H/F/P) on camera + Zoom.
- Verify: `make test` (unsandboxed shell) then `make app` + `codesign --verify --deep build/GestureCue.app`; launch with `make open`. QA checklists in docs/.
- Release notes: bump the build number with every staged fix so stale instances are visible in the window title; host-only updates via `make reinstall` need no reboot; `systemextensionsctl uninstall` is SIP-blocked — in-app Uninstall is the only reset path; one known minor pre-existing warning (`StudioViewModel.swift:256`, unused result).
- Where to continue: fix frictions from real services. Parked for later (specs on the working branch): mouse brush, split-view layout.
