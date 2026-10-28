# GestureCue → OBS → Zoom Setup

How to show GestureCue's composited video (camera + cards + paint) in Zoom,
Teams, or Meet using OBS Studio as a bridge. Video only — GestureCue never
touches the microphone, so keep using your normal mic in the meeting app.

Requires: GestureCue Build 17+, OBS Studio 28 or newer (macOS).

## 1. Grant OBS screen-capture permission (once)

OBS cannot capture windows without it; the capture stays black otherwise.

1. Open System Settings → Privacy & Security → Screen Recording.
2. Enable OBS (restart OBS if it was already running).

## 2. Start GestureCue output

1. Open GestureCue (`make open`), press **Start Camera**.
2. In the Camera panel, under **Output to OBS**, press **Start Output**.
3. A borderless **GestureCue Output** window appears showing video only —
   no buttons, no text, no window chrome. This is the capture source.
4. Pick **Resolution** (720p default; 1080p for sharper cards) and
   **Mirroring** (Auto follows the camera; override if the meeting app
   mirrors you again).

Do not minimize the Output window while live — a minimized window freezes
the capture. You may cover it with other windows; OBS keeps capturing it.
Drag it by its background if it is in the way.

## 3. Add it to OBS

1. In OBS, under Sources, press **+** → **macOS Screen Capture** → Create New.
2. Set Method to **Window Capture**, Window to **GestureCue Output**.
3. The feed fills the source (1280×720). Optionally set OBS Settings →
   Video → Base Resolution to 1280×720 to match.
4. Press **Start Virtual Camera** (Controls dock).

First run only — if OBS says the virtual camera is not installed: open
System Settings → General → Login Items & Extensions, scroll down to the
Extensions section (not "Open at Login"), open Camera Extensions, enable
OBS, authenticate, restart OBS, and press Start Virtual Camera again.

## 4. Select it in the meeting app

- Zoom: Settings → Video → Camera → **OBS Virtual Camera**.
- Teams / Meet: same — choose OBS Virtual Camera as the camera.

Everything GestureCue composites — card show/hide/next/previous/expand,
paint strokes, pointer — appears live in the meeting, driven by your
gestures (or the mouse/keyboard equivalents).

## Restarting the chain

If the picture in Zoom freezes or misbehaves, restart in this order:

1. In GestureCue: press **Stop Output**, then **Start Output** again.
2. In OBS: press **Stop Virtual Camera**, then **Start Virtual Camera**.
3. If still stuck: quit GestureCue (⌘Q), run `make open`, Start Camera,
   Start Output — then re-select OBS Virtual Camera in Zoom.

## Restarting GestureCue

Quitting GestureCue freezes the Zoom picture (OBS keeps sending its last
frame). To resume: Start Camera → Start Output in GestureCue; if OBS
still shows a stale frame, delete the Screen Capture source and add it
fresh — the old source stays bound to the dead pre-restart window. Then
Stop/Start Virtual Camera if needed.

## Troubleshooting

- Black capture in OBS: Screen Recording permission (step 1) is missing.
- "GestureCue Output" not in the window list: press Start Output first.
- Choppy video: use 720p; close heavy apps; keep OBS canvas at 1280×720.
- Backwards video: set Mirroring to Original (or Mirrored) explicitly.
- Card edges cut off: in OBS check canvas 1280×720 and source Transform
  → Fit to screen (no crop). Zoom tiles also center-crop aspects that do
  not match — if the full card shows in OBS, the crop is Zoom's tile:
  prefer Speaker view, or the Bottom card position, which survives
  side-cropping best.
- Card text looks backwards in Zoom: that is Zoom's self-view mirror
  ("Mirror my video", on by default) — attendees see it correctly.
  Uncheck it in Zoom Settings → Video to preview the true picture.
- Output window closed accidentally: press Start Output again (Stop, then
  Start if the button already shows Stop).
