# GestureCue

A native macOS app that lets a presenter control large, readable visual
presentation cards with hand gestures from the Mac's webcam — no keyboard or
mouse needed. Built primarily for Deaf and hard-of-hearing audiences, so they
can split attention between the interpreter, captions, slides, and speaker
without missing cues.

See [SPEC.md](SPEC.md) for scope, [AGENTS.md](AGENTS.md) for project rules,
and [docs/](docs/) for manual test checklists and the OBS/Zoom setup guide.

## Requirements

- macOS 14.0 or later (deployment target)
- Xcode 26 with the macOS SDK (built and tested with Xcode 26.6 / Swift 6.3)
- A built-in or USB webcam

## Build and run

```sh
make build   # compile
make test    # 169 XCTest tests (run in an unsandboxed shell)
make app     # stage build/GestureCue.app
make open    # restart + open the staged app
```

The app is ad-hoc signed ("Sign to Run Locally"), so it runs on your Mac
without a paid developer team.

## Camera permission

On first Start, macOS asks for camera access. If you deny it, the Camera panel
shows how to re-enable access (System Settings → Privacy & Security → Camera)
with a button that opens Settings. All video is processed on-device; nothing
leaves the Mac except MP4s you explicitly record, and the app never touches
the mic.

## Using the app

1. Press **Start Camera** and grant permission.
2. The camera ignores your hands while you sign. Hold an **open palm** still
   for ~2 s (or press **L**) to latch listening on; a green dot appears in
   the video feed. Hold a **still fist** 2 s (or press **L**) to stop.
3. While listening, hold a gesture still for ~0.5 s until the stability
   meter fills — the action fires. Moving your hand or fingers restarts
   the hold, so signing never triggers cards.

Default gesture mapping (reconfigurable in the Gesture Control panel; the
fist, index, and two-finger poses are unassigned by default because they
all occur in sign language):

| Gesture | Action |
|---|---|
| Open palm | Show Card |
| Thumbs-up | Hide Card |
| Thumb points right (your right) | Next Card |
| Thumb points left (your left) | Previous Card |
| Three fingers up | Expand/Collapse Card |

Equivalent mouse and keyboard controls (always available):

| Button | Shortcut |
|---|---|
| Show | ↑ |
| Hide | Esc |
| Previous | ← |
| Next | → |
| Expand/Collapse | E |
| Zoom picture in/out | + / − |
| Listen for commands | L |
| Record | R |

The **Program Output** monitor in the Camera panel shows the composited feed
(camera plus card overlay). **Start Output** opens it fullscreen for OBS
Window Capture → Virtual Camera → Zoom/Teams (see
[docs/OBS-ZOOM-SETUP.md](docs/OBS-ZOOM-SETUP.md)); **Record** saves the same
feed as a video-only MP4 to Movies ▸ GestureCue.

Cards live in a presentation catalog (create/rename/delete decks, import PDF
pages or PowerPoint slides as picture cards). Use the Card position control
(Bottom / Left / Right) to place the in-video card; the choice persists
across restarts. **Paint color** drives Finger Paint: enable Paint Mode, then
pinch thumb + index and drag to paint on the card (Undo/Redo/Clear included).
On a picture card, spread or pinch thumb + index (with the thumb raised) to
zoom the picture from the camera.

## Architecture

One shared capture pipeline feeds analysis, output, and recording:

```
AVFoundationVideoCaptureService (720p capture, frame fan-out)
 ├── HandGestureDetector ── Vision hand pose → classifier → state machine
 │                          → AppViewModel → GestureActionRouter → card store
 ├── ProgramOutputPipeline ── CardOverlayCompositor → VideoOutputService
 │                             (in-app monitor now; CoreMediaIO virtual
 │                              camera later — same seam, no rewrite)
 └── VideoRecorder ── program frames → user-initiated MP4 (H.264, no audio)
```

- `GestureCue/Camera` — `VideoCaptureService` protocol, AVFoundation
  implementation, `CameraManager` facade (permission/devices/status), preview.
- `GestureCue/Vision` — `HandPose` value type, `HandPoseDetector` (Vision).
- `GestureCue/Gestures` — geometric classifier, stabilizing state machine
  (hold-to-fire, wrist + fingertip stillness, debounce-by-release, cooldown),
  action router, detector, pinch-zoom tracker, command latch.
- `GestureCue/Output` — compositor/output protocols, card compositor, program
  monitor output, program pipeline, MP4 recorder.
- `GestureCue/Cards`, `ViewModels`, `Views`, `Models` — library, store,
  importer, wiring, UI.

Classification uses resolution-independent landmark ratios (no pixel
thresholds); all Vision/gesture work runs off the main thread. Protocols and
dependency injection keep every stage unit-testable with synthetic frames —
no camera required.

## Testing

169 XCTest unit tests in `GestureCueTests/` cover classification, confidence
thresholds, stabilization, hold-to-fire stillness, gesture→action mapping,
card state transitions, paint, zoom, the command latch, compositing, the
program pipeline, and MP4 recording (incl. a real H.264 encode of synthetic
frames). Camera/Zoom behavior additionally needs the manual checklists in
`docs/`.

## Limitations

- Single hand only (`maximumHandCount = 1`); the highest-confidence hand wins.
- Best with a plain background, good lighting, and the hand 1–3 ft from the camera.
- Gesture thresholds are tuned geometrically, not trained; unusual hand shapes
  or extreme camera angles may misclassify (reported as Unknown, never a guess).
- Thumb left/right directions were derived from code rather than hardware —
  verify on camera (see MT-10 in the Phase 1 checklist).
- No virtual camera yet: Zoom/Teams integration currently goes through OBS
  capturing the output window (see above).
- Sample cards are hand-written; no AI generation or speech recognition.

## Roadmap

1. **Virtual camera:** CoreMediaIO camera extension (`VirtualCameraService`)
   behind the existing `VideoOutputService` seam (may need a paid Apple
   signing identity to activate locally).
2. **AI-assisted cards:** short accessible message generation, kept out by
   design until a milestone spec covers the service and privacy story.
