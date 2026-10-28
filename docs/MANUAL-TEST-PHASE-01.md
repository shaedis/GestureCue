# Manual Test Checklist — Phase 1: Camera and Gesture Recognition

App: `build/GestureCue.app` (or Xcode `GestureCue` scheme, Debug).
Scope: everything in `SPEC.md` milestone 1 plus testing-round extras (five
gestures, card positions, paint, pictures, expand, mirroring).
Automated suite (96 XCTest tests) already passes; these cases cover what
automation cannot: real webcam, permission UX, and recognition feel.

Fill in Result (`[x] Pass` / `[x] Fail`) and Notes as you go.

- Tester:
- Date:
- macOS / Mac model:
- Camera(s):

## Setup

- [ ] S1 — Open `build/GestureCue.app` (or `make run`). Window shows Camera,
  Gesture Control, and Presentation Card panels. No crash on launch.
  Title bar shows the build number — after an update use `make open`
  (it restarts the app); plain `open` reuses a running old instance.

## Camera (MT-01…MT-07)

- [ ] MT-01 — Press **Start Camera**, grant permission. Live preview appears,
  status reads "Running".
- [ ] MT-02 — Revoke access (System Settings → Privacy & Security → Camera),
  restart app, press Start. Status reads "Permission denied", guidance text
  shows, **Open System Settings** opens Settings. Re-grant after.
- [ ] MT-03 — Press **Stop Camera**: preview goes dark, status reads "Stopped".
  Press Start again: capture resumes without restart.
- [ ] MT-04 — Camera picker lists available cameras (note count; if one,
  picker shows it selected and disabled state is sane).
- [ ] MT-05 — Hold a hand to the camera: green landmark dots track joints.
  Toggle **Show hand landmarks** off/on: overlay hides/appears.
- [ ] MT-06 — **Program Output** monitor shows the camera feed; toggle
  **Enable program output** off/on: monitor freezes/clears, then resumes.
- [ ] MT-07 — With camera running, disconnect the camera (unplug / disable):
  a clear error/disconnect status appears (no hang). Reconnect and press
  Start: capture recovers.

## Command window (PA-01…PA-04)

- [ ] PA-01 — Launch state is **Signing** (gray banner, "hands ignored").
  Sign freely for 10 s: no card action fires; diagnosis shows PAUSED.
- [ ] PA-02 — Hold **open palm** still 2 s: banner turns green, a green dot
  appears top-left in the program monitor and output window. Keep holding
  the palm: its own command must NOT fire.
- [ ] PA-03 — While listening, hold **thumb right**: Next fires; the latch
  stays on through gaps. Hold a **still fist** 2 s (or press L / Stop):
  dot vanishes, back to Signing. Panel shows idle time left (5-min
  auto-end is code-tested; spot-check 10 s that it falls).
- [ ] PA-04 — **L** key / Listen button arms and ends early. Quit and
  relaunch: pause state persists. Card buttons/keys work while paused.

## Gestures (MT-08…MT-14)

Precondition: arm listening first (palm hold, button, or L key).

Hold each gesture still ~0.5–1 s, hand 1–3 ft from camera, palm facing it. Moving your hand or fingers restarts the hold (meter drops); a shaking fingertip must never fire.

- [ ] MT-08 — **Open palm** → card appears; "Last Action" shows Show Card
  via Open Palm; stability meter fills; confidence % looks sane (>~50%).
- [ ] MT-09 — **Thumbs-up** → card hides; feedback shows Hide Card.
  **Closed fist** (unassigned by default) → "No action assigned".
- [ ] MT-10 — **Thumb points right** (your own right) → advances to next
  card and shows it; position label updates (e.g. "2 of 4"). **Index up**
  (unassigned) → nothing. If left/right feel swapped, report it.
- [ ] MT-11 — Keep holding a gesture after it fires: it must NOT refire
  repeatedly. Remove hand, show gesture again: fires again.
- [ ] MT-12 — Remove hand / show a non-listed pose (e.g. OK sign,
  four fingers without the thumb): readout shows Unknown, nothing fires,
  no phantom actions over 10 s.
- [ ] MT-13 — Remap (e.g. Open Palm → Next Card): behavior changes
  immediately; quit and relaunch: mapping persists.
- [ ] MT-14 — Set a gesture to **None** and perform it: feedback shows
  "No action assigned", no card change.

## Cards, mouse, keyboard (MT-15…MT-18)

- [ ] MT-15 — **Show / Hide / Previous / Next** buttons work; hidden state
  shows the "Card hidden" placeholder naming the Show gesture.
- [ ] MT-16 — Keyboard: **↑** shows, **Esc** hides, **→**/**←** move
  next/previous, **E** expands/collapses, **+**/**−** zoom the picture.
- [ ] MT-17 — Card text is large, high-contrast, readable from a few feet;
  all four sample cards render correctly.
- [ ] MT-18 — Basic VoiceOver pass: all buttons, pickers, toggles, and the
  card announce sensible labels (no "button" / empty labels).

## Privacy (MT-19)

- [ ] MT-19 — At no point does macOS prompt for **microphone** access;
  camera prompt appears only on first Start.

## Back gesture + distance (MT-20…MT-22, added after first test round)

- [ ] MT-20 — **Thumb points left** (your own left) → goes to the previous
  card and shows it; from card 1 it wraps to the last card. Feedback names
  the gesture. Two fingers (unassigned) → nothing.
- [ ] MT-21 — **Previous** button and **←** key go back one card.
- [ ] MT-22 — Hand-distance diagnostic: hold gestures close, then at arm's
  length. Record for the far case: (a) "No hand detected" + no landmark
  dots (Vision miss), or (b) dots visible but Unknown/low confidence
  (classification miss). The diagnosis line under the hand indicator names
  the cause (per-finger verdicts, thumb spread, ?reason) — copy it into
  your report. Note which gestures fail and at what distance.
- [ ] MT-23 — Card position: switch Bottom/Left/Right in the Camera panel.
  Program monitor shows the banner / left panel / right panel with readable
  text; opposite side stays clean video. Quit and relaunch: position persists.
- [ ] MT-24 — Start Output: the "GestureCue Output" window opens showing
  the composited feed large; it matches the small monitor (same card,
  position, paint). Card gestures update it live. Stop Output hides it:
  no errors, main window unaffected. (Output-window coverage now lives in
  the Phase 4 checklist OB-01…OB-09.)
- [ ] MT-25 — Finger paint: enable Paint Mode, pick Yellow/Red. Colored
  pointer follows your index in the video; pinch thumb+index and drag to
  paint on the card; release ends the stroke. Palm/thumb poses still drive
  cards; index-family gestures never fire cards. Undo/Redo/Clear work;
  strokes survive card switches per card. Strokes land under your fingertip
  as seen in the program monitor (mirrored like the preview).
- [ ] MT-26 — Pictures: each sample card already shows a funny picture
  below the texts in the panel AND upright in the video at any position.
  Add Picture… replaces it with your photo; Remove Picture clears it.
  Paint strokes survive picture changes.
- [ ] MT-27 — Rapid motion: wave/sign naturally ~10 s. No action fires;
  meter resets instead of filling.
- [ ] MT-28 — Expand: **three fingers up** → card fills the video frame
  (text + picture scale up, position preset ignored); show it again →
  card returns to its Bottom/Left/Right spot. "Last Action" names
  Expand/Collapse. Paint strokes stay visible on the card while expanded.

## Robustness notes (record, don't gate)

- Dim-light behavior:
- Misclassifications seen (pose → wrong action):
- Program-monitor smoothness / lag:
- Crashes or hangs (attach Console excerpt):

## Sign-off

- [ ] Phase 1 accepted for manual verification — Tester, date:
- [ ] Blockers for Phase 2 (if any):

Future checklists live alongside this file as `MANUAL-TEST-PHASE-0X.md`.
