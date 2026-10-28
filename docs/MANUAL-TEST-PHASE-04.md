# Manual Test Checklist — Phase 4: OBS / Zoom Output

App: `build/GestureCue.app` (Build 17+).
Scope: chromeless capture window, presenter output controls, OBS bridge.
OB-08 needs OBS Studio + a meeting app; everything else needs only GestureCue.

Fill in Result (`[x] Pass` / `[x] Fail`) and Notes as you go.

- Tester:
- Date:
- macOS / Mac model:
- Camera(s):

## Output window (OB-01…OB-03)

- [ ] OB-01 — Camera running, press **Start Output**: a borderless
  "GestureCue Output" window appears showing video only — no buttons, no
  text, no title bar. Content matches the small program monitor (same
  card, position, paint). Status reads "Output Running".
- [ ] OB-02 — Press **Stop Output**: window hides, status reads Stopped.
  Press Start again: window reappears with live video, no errors.
- [ ] OB-03 — With the camera stopped, Start Output is disabled.

## Presenter controls (OB-04…OB-06)

- [ ] OB-04 — Resolution: switch 720p → 1080p. Status updates, capture
  continues (a brief glitch is OK), output looks sharper. Switch back.
  Quit and relaunch: the selected resolution persists.
- [ ] OB-05 — Mirroring: Auto with the built-in camera reads Mirrored.
  Force Original: output video flips relative to the preview. Force
  Mirrored: flips back. Status tracks each change. Setting persists
  across relaunch.
- [ ] OB-06 — Output content: with output running, show/hide/next/expand
  cards and paint a stroke (Paint Mode). Every change appears fullscreen
  in the capture window, including the paint pointer.

## OBS bridge (OB-07…OB-08)

- [ ] OB-07 — The capture window drags by its background; OBS's Window
  Capture list shows "GestureCue Output" while running.
- [ ] OB-08 — Follow `docs/OBS-ZOOM-SETUP.md` end to end: OBS shows the
  feed, Virtual Camera starts, Zoom (or Teams/Meet) displays the GestureCue
  feed as its camera, updating live with gestures.

## Robustness (OB-09…OB-10)

- [ ] OB-09 — Stop the camera while output is running: no crash (output
  holds its last frame). Restart the camera: output resumes live video.
- [ ] OB-10 — Single instance: with the app running, run `make open`
  again (or double-click the app): no second Dock icon appears; the
  running app activates instead.

## Recording (REC-01…REC-03)

- [ ] REC-01 — Camera running, press **Record**: red state + elapsed
  counting; navigate cards, paint, zoom. Stop: status names the MP4;
  Reveal opens Movies ▸ GestureCue; file plays in QuickTime with
  cards/paint burned in and no audio track. (Listening dot appears if
  listening — end listening first for a clean feed.)
- [ ] REC-02 — Record is disabled with the camera stopped. Stopping the
  camera mid-recording ends it cleanly (saved file, no hang).
- [ ] REC-03 — Switch resolution mid-recording: recording continues,
  dropped-frame count shows, file plays.

## Sign-off

- [ ] Phase 4 output accepted — Tester, date:
- [ ] Blockers (if any):
