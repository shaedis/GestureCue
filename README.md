# GestureCue

A native macOS app that puts large, readable visual presentation cards
*inside* the presenter's own webcam feed, controlled by hand gestures —
no keyboard or mouse needed. Built primarily for Deaf and hard-of-hearing
audiences: instead of splitting attention between interpreter, captions,
slides, and speaker, viewers get the signer and the content in one frame.
An AI Visual Education Studio (Meta Muse Spark + Muse Image) turns difficult
source texts into illustrated lesson decks that present the same way.

See [SPEC.md](SPEC.md) for scope, [AGENTS.md](AGENTS.md) for project rules,
and [docs/](docs/) for setup guides and manual test checklists.

## Features

- **Gesture card control** — 8 webcam hand gestures (show, hide, next,
  previous, expand…) with stillness-gated holds; a signing-safe latch
  ignores hands until you arm a command window, so signing never
  triggers actions.
- **AI Visual Education Studio** — Meta Muse Spark plans illustrated
  lessons from pasted text, PDFs, or PowerPoint; Muse Image illustrates
  them; exact content (fractions, equations) renders as precise local
  diagrams. Faithful mode splits existing decks verbatim with your
  original pictures kept.
- **Cards inside your video** — lessons composite into the webcam feed
  (720p/1080p) and reach Zoom/Teams through the native **GestureCue
  Camera**, with a fullscreen window for OBS capture as fallback.
- **Paint & highlight live** — finger paint with undo/redo, a fading
  two-finger brush (snaps to lines and circles, stays readable over
  photos and diagrams), and pinch-to-zoom on pictures.
- **Catalog & recording** — presentation library with collections,
  one-click MP4 recording of the program feed, persisted paint strokes.
- **Private by design** — camera-only, processed live on-device; only
  approved lesson sources ever reach the Meta API. No microphone, no
  analytics, no tracking.

## Requirements

- macOS 14.0 or later (deployment target)
- Xcode 26 with the macOS SDK (built and tested with Xcode 26.6 / Swift 6.3)
- A built-in or USB webcam

## Build and run

```sh
make build   # compile
make test    # 363 XCTest tests (run in an unsandboxed shell)
make app     # stage build/GestureCue.app
make open    # restart + open the staged app
```

On `main` the app is ad-hoc signed ("Sign to Run Locally"), so it runs on
your Mac without a paid developer team. The `virtual-camera` and
`visual-pedagogy` branches sign with team `X8YHS47G23` instead, because the
camera extension requires a provisioning profile — `make` needs an
unsandboxed shell for portal access.

## Install

1. Build and stage: `make app` → `build/GestureCue.app`.
2. Copy it to `/Applications` (required for the virtual-camera system
   extension): `cp -R build/GestureCue.app /Applications/GestureCue.app`
   (or `make reinstall`, which restages + replaces + reopens).
3. Open the `/Applications` copy and confirm the window title shows the
   expected build number. If macOS blocks the first launch (Gatekeeper),
   right-click → Open once to approve it.
4. Press **Start Camera**, grant camera access when asked, and pick a deck
   in the catalog. For Zoom/Teams: press **Enable Camera** once, approve
   the system extension in System Settings if asked, then select
   **GestureCue Camera** in Zoom (full steps: Virtual camera below +
   [docs/VIRTUAL-CAMERA-SETUP.md](docs/VIRTUAL-CAMERA-SETUP.md)).
5. For the AI Studio: paste a Meta API key into the Studio's key field
   (stored in the Keychain) — see AI Visual Education Studio below.

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

The **Program Monitor** in the Camera panel shows the composited feed
(camera plus card overlay). **Open Window** opens it fullscreen for OBS
Window Capture → Virtual Camera → Zoom/Teams (see
[docs/OBS-ZOOM-SETUP.md](docs/OBS-ZOOM-SETUP.md)); **Record** saves the same
feed as a video-only MP4 to Movies ▸ GestureCue.

Cards live in a presentation catalog (create/rename/delete decks, import PDF
pages or PowerPoint slides as picture cards). Use the Card position control
(Bottom / Left / Right / Video + Card) to place the in-video card; the choice persists
across restarts. **Paint color** drives Finger Paint: enable Paint Mode, then
pinch thumb + index and drag to paint on the card (Undo/Redo/Clear included).
On a picture card, spread or pinch thumb + index (with the thumb raised) to
zoom the picture from the camera. Anytime while listening, a **two-finger
brush** (index + middle) paints freehand strokes that fade after ~1.5 s —
straight drags snap to clean lines, loops to ellipses, and an adaptive halo
keeps strokes readable over photos and white diagrams. Brushing counts as
activity, so the 5-minute command window never expires mid-stroke.

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
62) — earlier builds fail at different stages below.

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

## AI Visual Education Studio

On branch `visual-pedagogy`, the Studio window turns difficult source texts
(history, fractions, science, Bible passages) into illustrated lesson decks
using the Meta Model API (`https://api.meta.ai/v1`): **Muse Spark**
storyboard planning plus **Muse Image** illustrations, with deterministic
local diagrams (fraction circles, number lines, timelines, cause→effect)
for exact content. Generated decks save into the catalog and present
inside the composited video like any other cards.

Setup:

1. Get a key at [dev.meta.ai](https://dev.meta.ai) and paste it into the
   Studio's key field — it is stored in the Keychain, never in files.
2. Import source (paste text, PDF, or PowerPoint), pick audience / level /
   subject / style, and tick the per-lesson approval box: nothing is
   transmitted until you approve each lesson.
3. Generate, review each draft (retitle, relabel, edit prompts, refresh
   text for free, regenerate only changed cards), then save to a collection.

PDF and PowerPoint imports run in faithful mode: the model splits your
pages/slides verbatim to fit video cards — no rewritten text, your original
images reattached, no new illustrations or diagrams, and no image API cost.

Privacy: only your approved source text and illustration prompts leave the
Mac, to the Meta Model API. Webcam frames are never transmitted. See the
approval gate in `GestureCue/AI/StudioViewModel.swift`.

Integration notes: the client speaks the OpenAI-compatible `v1` endpoints
(`chat/completions` for `muse-spark-1.3` plans, images for `muse-image-1.0`
art) with a strict JSON Schema the app enforces on every plan (decoder
validation, one retry on 429/5xx, per-status errors). Costs stay bounded:
diagrams and text refreshes render locally for free, faithful imports make
no image calls at all, and per-card regeneration refreshes only what you
edited.

Manual checklist (key round-trip, import, generate, review, save, present
over Zoom): [docs/MANUAL-TEST-STUDIO.md](docs/MANUAL-TEST-STUDIO.md).
The consolidated human gate (ST + VC steps with tick boxes) is
[docs/USER-VERIFICATION-GATE.md](docs/USER-VERIFICATION-GATE.md).

## What was built

- **Foundation (pre-hackathon, `main`):** 8-gesture recognition with
  stillness-gated holds, the signing-safe command latch, finger paint,
  fading brush, presentation catalog with PDF/PowerPoint import, OBS
  output window, MP4 recording, and the native CoreMediaIO virtual
  camera.
- **Hackathon (Builds 46–76, `visual-pedagogy`, merged):** the AI Visual
  Education Studio end to end (Meta Muse Spark planning + Muse Image
  art + local diagrams, two generation modes, deck round-trip,
  original-image reattachment, adult prose, collections), Video + Card
  placement, brush shape-snapping, the adaptive legibility halo, and
  the activity-aware command window.

## Architecture

One shared capture pipeline feeds analysis, output, and recording:

```
AVFoundationVideoCaptureService (720p/1080p capture, frame fan-out)
 ├── HandGestureDetector ── Vision hand pose → classifier → state machine
 │                          → AppViewModel → GestureActionRouter → card store
 ├── ProgramOutputPipeline ── CardOverlayCompositor → VideoOutputService
 │                             (in-app monitor, OBS window, MP4 recorder,
 │                              native CoreMediaIO virtual camera)
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

363 XCTest unit tests in `GestureCueTests/` cover classification, confidence
thresholds, stabilization, hold-to-fire stillness, gesture→action mapping,
card state transitions, paint, brush shape-snapping, the adaptive halo,
mouse-brush mapping, zoom, the command latch, compositing, the program
pipeline, MP4 recording (incl. a real H.264 encode of synthetic frames),
and the AI Studio (API client parsing, credential stores, source import,
illustration composition, diagram validation, deck round-trip, PPTX/PDF
image extraction).
Camera/Zoom/API behavior additionally needs the manual checklists in `docs/`
plus live runs against the real Meta API.

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
- No speech recognition; no sign-language instruction generation.
- Studio plans are strict-JSON-Schema-constrained plus decoder
  validation, with one automatic retry on rate limits / transient
  server errors.
- No visual layout editor (resize/reposition) and no cross-deck card
  move/duplicate yet.

## Roadmap

1. **Virtual camera:** working and merged to `main`
   (CoreMediaIO camera extension behind the `VideoOutputService` seam,
   verified on camera in Zoom + QuickTime); remaining: VC-01..07
   checklist. Continued work happens on branch `virtual-camera`.
2. **AI Visual Education Studio:** implemented on branch
   `visual-pedagogy` (Meta Muse Spark + Muse Image, local diagrams,
   catalog round-trip, original-image reattachment, brush legibility,
   Build 76); user-verified ST-01..14 + flows H/F/P; remaining:
   ST-15, VC-01/05, and the merge decision.
