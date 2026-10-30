# User verification gate — Build 62 (branch `visual-pedagogy`)

Everything below needs a human: the live API key, eyes on real cards,
a camera, and Zoom. Work top to bottom, tick each box, and paste the
results back (pass/fail + one line each). Nothing here may be marked
passed without doing it. Failing step: stop, paste the step ID plus
what you saw (and any error text), and wait for a fix.

Setup (once): `cp -R build/GestureCue.app /Applications/GestureCue.app`,
open the `/Applications` copy, confirm the title says Build 62.

## Part 1 — AI Studio (ST-01..12)

Key + approval:

- [X] ST-01 Save your Meta API key in the Studio, quit, relaunch: key
      still present, key field empty. (Keychain round-trip.)
- [X] ST-02 Fresh source, approval unticked: Generate disabled. Tick it,
      import another source: tick resets. Tick again, edit the source
      text: tick resets. (Per-lesson approval.)

Import:

- [X] ST-03 Paste ~1 page of history text: title/note sane, Generate
      enables after approval.
- [x] ST-04 Import a PDF and a PowerPoint: extracted text matches the
      file (spot-check); oversized sources show the truncation note.
      Faithful-mode caption shows; generating yields verbatim splits
      (source wording kept, no new illustrations).

Generate + review:

- [x] ST-05 History lesson, 5 cards: every draft has title, short body,
      labels, illustration; check 2+ dates against your source text.
- [x] ST-06 Fractions lesson, 5 cards: 1/2 = 2/4 and 1/2 + 1/4 = 3/4
      correct, numbers on diagrams (not in pixels), nothing covered.
- [x] ST-07 Edit one title + one illustration prompt: only that card
      shows the dirty marker; Regenerate Changed refreshes just it;
      Refresh Text updates wording without new API art.
- [x] ST-08 Save to a collection, Edit Existing Deck: artwork, prompts,
      labels return; untouched re-import shows no dirty markers.

Present on video:

- [x] ST-09 Show the saved lesson on camera: every card readable in
      Program Output, nothing clipped, signer area (top ~70%) clear.
- [x] ST-10 In Zoom/QuickTime pick GestureCue Camera: lesson cards in
      the call; Next/Previous gestures advance while streaming.
- [x] ST-11 Two-finger brush highlights text live and fades; Expand
      (E / three fingers) fills the frame for small tiles.
- [ ] ST-12 Start a generation, press Cancel: stops cleanly, partial
      drafts editable, no stuck spinner or error sheet.

## Part 2 — Virtual camera (VC-01..07)

Background + troubleshooting:
[docs/VIRTUAL-CAMERA-SETUP.md](VIRTUAL-CAMERA-SETUP.md). Host-only
update, so no reboot expected: `make reinstall` if a newer build
lands mid-gate.

- [ ] VC-01 Enable from clean state: Activating → (approval) → Live.
- [x] VC-02 Zoom/QuickTime lists GestureCue Camera; selecting it shows
      the composited feed (camera + card), not the raw webcam.
- [x] VC-03 Next/Previous/paint gestures work while streaming; feed
      stays live throughout.
- [ ] VC-04 Stop Camera: status back to Installed; Zoom freezes or goes
      dark; app keeps running.
- [ ] VC-05 Uninstall: extension disappears from camera lists after
      deactivation. (Re-enable afterwards to continue.)
- [x] VC-06 Restart app: status shows Installed, not Live; Enable
      resumes streaming.
- [ ] VC-07 Slate: extension active but app streaming off → clients see
      the "Enable the virtual camera in GestureCue" slate.

## Part 3 — Demo flows (Task 4)

Run each end to end; every step maps to a Part 1/2 box already ticked
above — this pass proves the whole chain in one sitting.

Flow H (history, Visual Educational mode):

- [ ] H1 Import a history PDF (ST-04) → H2 generate illustrated cards
      (ST-05) → H3 edit + approve (ST-07) → H4 save + reopen (ST-08) →
      H5 select in catalog → H6 show in live video (ST-09) → H7 finger
      highlight (ST-11) → H8 verify in Zoom via GestureCue Camera
      (ST-10) → H9 record MP4 + play back (REC-01 in
      MANUAL-TEST-PHASE-04; file lands in Movies/GestureCue).

Flow F (fractions, Visual Educational mode): same 9 steps with a
fractions text (ST-06 math checks at step 2).

Flow P (faithful mode): import a real PowerPoint → verify faithful
caption + verbatim splits with green fidelity lines (ST-04).

## Report back

For each step: ID + PASS/FAIL + one line (e.g. `ST-06 PASS — 2/4=1/2
diagram exact, band clear of labels`). On any FAIL add: what you
expected, what you saw, and any on-screen error text. Screenshot the
Zoom view for ST-10 if you can.

After all green: commit + push + tag on your go, then the merge
decision (details in PROGRESS.md Build 51 entry).
