# GestureCue Virtual Camera — Setup & Manual Test (branch: virtual-camera)

The `virtual-camera` branch adds a native macOS virtual camera: Zoom and Teams
see **“GestureCue Camera”** directly, no OBS needed. The A line (`main`) is
untouched; this doc only applies to this branch.

## How it works

- `GestureCueCameraExtension/` — a CoreMediaIO Camera Extension (`.systemextension`,
  bundle `com.gesturecue.app.cameraextension`) embedded in the app at
  `Contents/Library/SystemExtensions/`. It publishes one device,
  “GestureCue Camera”, with a source stream (720p) and a sink stream.
- The host app (`GestureCue/Output/VirtualCameraService.swift`) finds the sink
  stream, scales program frames to 1280×720, and enqueues them. The extension
  republishes them on its source stream, which Zoom/Teams consume.
- With no host streaming, the source stream shows a “GestureCue Camera” slate.
- Activation uses `OSSystemExtensionRequest` (`SystemExtensionManager.swift`).
  Status lives in the app panel: Virtual Camera section.

## Requirements

- App must be signed with a Developer ID / Apple Development identity under
  team `X8YHS47G23` (project uses Automatic signing).
- The `.app` must live in `/Applications` for macOS to activate the extension.
- One approval in System Settings → General → Login Items & Extensions.
- A reboot may be required after first approval (macOS decides).

## Install

1. `make app` (or `make build`), then copy the staged app:
   `cp -R build/GestureCue.app /Applications/GestureCue.app`
2. Open `/Applications/GestureCue.app`, start the camera.
3. In the control panel → Virtual Camera → **Enable Camera**.
4. If status says “Needs your approval”, press **Open Settings** (or open
   System Settings → General → Login Items & Extensions, scroll to **Camera
   Extensions**, and switch GestureCue on). Authenticate if asked, reboot
   if asked, then Enable again.
5. Status **Live** means frames are flowing.

## Manual checklist

- VC-01 Enable from clean state: status goes Activating → (approval) → Live.
- VC-02 Zoom/Teams/FaceTime/QuickTime camera list shows “GestureCue Camera”;
  selecting it shows the composited feed (camera + card), not the raw webcam.
- VC-03 Gesture commands (next/back/paint) work while streaming; feed stays live.
- VC-04 Stop Camera: status back to Installed; Zoom feed freezes on last frame
  or goes dark (client-dependent), app keeps running.
- VC-05 Uninstall: extension disappears from camera lists after deactivation.
- VC-06 Restart app: status shows Installed (not Live); Enable resumes.
- VC-07 Slate: with extension active but app streaming off, clients see the
  “GestureCue Camera / Enable the virtual camera in GestureCue” slate.

## Troubleshooting

- Requires Build 42+ (window title; current is Build 45). Earlier branch
  builds can't find or activate the extension, or can't feed it frames
  (Build 40/41 cropped 1080p captures in Zoom).
- “Camera extension not found in this app bundle”: a stale instance is still
  running (quit first — the single-instance guard keeps the old one), or an
  old staged copy. Check the title says the newest build, then re-copy.
- “Missing entitlement com.apple.developer.system-extension.install”: the app
  wasn't signed with its entitlements (fixed in Build 36 via
  CODE_SIGN_ENTITLEMENTS). Re-copy the newest staged app.
- Xcode “device isn't registered” / “No profiles”: build once in the Xcode
  GUI (⌘B) and accept Mac registration; headless `make` works after that
  (run it unsandboxed — portal and keychain access fail sandboxed).
- No approval prompt and status stuck at Activating: the app is not in
  `/Applications`, or a previous failed activation needs a reboot first.
- Zoom shows a black frame: Enable Camera in GestureCue first; the slate only
  appears once the device streams.
- Conflicts: only one app can feed the sink; quit other virtual cameras
  (OBS Virtual Camera) if the feed stalls.
- Updating to a new build: host-only changes (no files under
  `GestureCueCameraExtension/`) need no reboot — `make reinstall`, open
  the /Applications copy, Start camera, Enable Camera once. The staged
  extension (same version+bits) is reused as-is.
- A `waiting to uninstall on reboot` line BLOCKS fresh extension
  launches: if no `cameraextension` process runs and no client lists the
  device, try Uninstall → Enable once (all camera clients quit); if the
  process still won't start, reboot — the pending generation clears at
  boot and the current version launches. Reboot only in this case, never
  for routine host-only updates.
- Never `make clean` between host-only iterations: a full rebuild
  relinks the extension binary, which macOS may treat as a new
  generation. Incremental builds leave it byte-identical.

## Design notes (why it looks like this)

- Sink-stream IPC, no custom XPC: the host talks to the extension only through
  CoreMediaIO sink/source streams, so no extra Mach service or entitlements.
- Fixed 720p BGRA: one negotiated format keeps the extension small; the host
  scales (passthrough when already 720p).
- No mic: the device exposes video only.
- Send-side drops instead of blocking: the gesture pipeline never waits on a
  video client.
