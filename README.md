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
make test    # 179 XCTest tests (run in an unsandboxed shell)
make app     # stage build/GestureCue.app
make open    # restart + open the staged app
```

On `main` the app is ad-hoc signed ("Sign to Run Locally"), so it runs on
your Mac without a paid developer team. This branch (`virtual-camera`) signs
with team `X8YHS47G23` instead, because the camera extension requires a
provisioning profile — `make` needs an unsandboxed shell for portal access.

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

## Virtual camera

GestureCue also publishes its composited feed as a native
**“GestureCue Camera”** (720p) that Zoom and Teams can select directly — no
OBS needed. This requires a paid Apple developer team for signing (team
`X8YHS47G23`), macOS approval of the system extension, and the app in
`/Applications`.

Setup (first time):

1. **Accept the Program License Agreement (PLA).** Sign in at
   [developer.apple.com/account](https://developer.apple.com/account) with
   the Apple ID that holds the paid membership. If an agreement update is
   pending, a banner at the top asks you to review it — open it, check the
   box, and accept. (Only the Account Holder can accept; it takes effect
   within minutes.)
2. **Register this Mac in Xcode.** Open Xcode → Settings (⌘,) → Accounts,
   and confirm your Apple ID is listed with the team. Then open
   `GestureCue.xcodeproj`, select the **GestureCue** scheme with destination
   **My Mac**, and press ⌘B. If Xcode reports the Mac isn't registered,
   accept its offer to register it. This one GUI build also lets Xcode
   create the provisioning profile; headless `make` works after that.
3. `make app` (unsandboxed shell), quit any running copy, then
   `cp -R build/GestureCue.app /Applications/GestureCue.app`.
4. Open `/Applications/GestureCue.app`, confirm the title shows the newest
   build, start the camera, and press **Enable Camera** in the Virtual
   Camera section.
5. **Approve the extension.** When the status says “Needs your approval”,
   press **Open Settings** in the Virtual Camera section (or open System
   Settings → General → Login Items & Extensions, scroll to **Camera
   Extensions**, and switch GestureCue on). Authenticate if asked, then
   press Enable Camera again. If macOS asks for a reboot, reboot and
   Enable once more — status **Live** means frames are flowing.

Full manual checklist (VC-01..07): [docs/VIRTUAL-CAMERA-SETUP.md](docs/VIRTUAL-CAMERA-SETUP.md).
Status: verified working on camera (Build 42) — Zoom and QuickTime show
the composited feed.

Updating to a newer build (host-only change, nothing under
`GestureCueCameraExtension/`) needs no reboot: `make reinstall`, open the
`/Applications` copy, Start camera, Enable Camera once. The panel reads
“waiting for the camera device…” until frames truly flow, then flips to
Live by itself.

### Troubleshooting

Always test with the newest staged build (window title; currently Build
42) — earlier builds fail at different stages below.

- **“Camera extension not found in this app bundle”**: a stale instance is
  still running (quit first — the single-instance guard keeps the old one),
  or an old staged copy. Check the newest build number in the title, then
  re-copy.
- **“Missing entitlement com.apple.developer.system-extension.install”**:
  the running build predates the entitlement fix (Build 38+). Re-copy the
  newest staged app.
- **“Extension not found in App bundle / unable to find any matched
  extension”**: the extension filename must equal its bundle ID and the
  plist must declare `SYSX` (fixed in Build 37+). Re-copy.
- **“extension category returned error”**: the mach service name must sit
  inside an entitled App Group (fixed in Build 38+ via the
  `X8YHS47G23.com.gesturecue.app` group). Re-copy. Diagnose further with
  `systemextensionsctl list` and the sysextd log.
- **Stuck on “waiting for the camera device…”**: the device isn't
  published. Check `pgrep -afl -i cameraextension` (empty = process never
  launched) and `systemextensionsctl list | grep -i gesturecue`. Any
  `waiting to uninstall on reboot` line blocks fresh launches: quit all
  camera clients, Uninstall, Enable once; if no process starts, reboot
  (clears the pending generations), then Enable. The `systemextensionsctl
  uninstall` CLI is SIP-blocked — use the in-app Uninstall button.
- **Fresh device invisible to the app but visible in QuickTime/Zoom**:
  quit and reopen GestureCue (stale per-process HAL view), then Enable —
  no reboot needed.
- **Zoom shows the slate but no video**: the host can't see the sink.
  Re-copy the newest build, Enable, then inspect the frame path with:
  `log show --last 10m --predicate 'subsystem BEGINSWITH "com.gesturecue"' --style compact | tail -40`
- **Xcode “PLA Update available”**: accept the Program License Agreement in
  your developer account, then retry.
- **Xcode “device isn't registered” / “No profiles”**: build once in the
  Xcode GUI and accept Mac registration; headless `make` works after that
  (run it unsandboxed — portal and keychain access fail sandboxed).
- **Zoom shows a black frame**: press Enable Camera in GestureCue first.
- **Conflicts**: quit other virtual cameras (e.g. OBS Virtual Camera) if the
  feed stalls.

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
- Zoom/Teams integration works two ways: the native virtual camera (see
  Virtual camera above, verified working on camera), or OBS capturing
  the output window (see above) as a fallback.
- Sample cards are hand-written; no AI generation or speech recognition.

## Roadmap

1. **Virtual camera:** working and merged to `main`
   (CoreMediaIO camera extension behind the `VideoOutputService` seam,
   verified on camera in Zoom + QuickTime); remaining: VC-01..07
   checklist. Continued work happens on branch `virtual-camera`.
2. **AI-assisted cards:** short accessible message generation, kept out by
   design until a milestone spec covers the service and privacy story.
