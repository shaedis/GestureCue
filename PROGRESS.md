# GestureCue — Progress

## Phase 1: Camera and gesture recognition — automated PASSED, manual sign-off PENDING

> Not marked COMPLETE: manual hardware sign-off by the user is still required.

Milestone 1 implemented per `SPEC.md` (native macOS app, Vulkan-free):
gesture-controlled presentation cards over a shared 720p capture pipeline,
plus virtual-camera-ready program output (compositor → output service seam).

- Features implemented:
  - Live camera preview, Start/Stop, permission flow + denied guidance,
    multi-camera selection, disconnect/interruption handling.
  - Vision hand landmarks + overlay; open-palm / fist / index-up classification
    (geometric, resolution-independent); stability, debounce-by-release,
    cooldown, unknown/no-hand states; configurable gesture→action mapping.
  - 4 sample cards; Show/Hide/Next via gestures, buttons, and keys (↑/Esc/→).
  - Program-output monitor (composited camera + card overlay) proving the
    composite→output path for future OBS/virtual-camera use.
- Build: `xcodebuild -scheme GestureCue` Debug — SUCCEEDED, 0 warnings.
  Bundle verified: `NSCameraUsageDescription` present, ad-hoc signed, LSMinimumSystemVersion 14.0.
- Tests: 38 XCTest tests, 38 passed, 0 failures (classifier, state machine,
  router, card store, compositor/pipeline incl. real Vision request on synthetic frame).
- Known issues: none in automated scope.
- Manual hardware tests still required: real-webcam recognition accuracy,
  permission prompt flow, program-monitor smoothness, multi-camera switching.
- Gate note: headless `xcodebuild test` needed one unsandboxed run (sandbox
  blocks the test runner's power assertion); suite itself is standard.

### Phase 1 extension (user testing round 1)

- Added two-fingers-up → Previous Card (+ Previous button/← key); saved
  mappings migrate to v2 defaults.
- Far-hand tolerance: state machine absorbs ≤2 gap frames; confidence gate
  0.45 → 0.35; new hand detected/not-detected indicator for diagnosis.
- Tests: 48/48 pass (3 state-machine tests re-specified for gap tolerance;
  obsolete two-fingers-unknown test removed). Manual re-verify: MT-08…MT-14,
  MT-20…MT-22.

## Phase 2: Cards inside the video — NOT STARTED

Requires (reconciled): in-video card rendering via layout-aware
`VideoCompositor`, drag/resize/presets, composition modes
(overlay/side-by-side), appearance, persistence. Blocked on Phase 1 manual
sign-off.

## Phase 3: Finger annotation — NOT STARTED

Requires (reconciled): Pointer Mode, fingertip tracking, Red/Yellow color
buttons, colored pointer, pinch-drag strokes, per-card undo/redo/clear,
mode safety. Spotlight deferred. Blocked on Phase 2.

## Phase 4: Video composition + Zoom integration — NOT STARTED

Requires: OBS output window + docs, CoreMediaIO extension investigation,
presenter output controls. Needs user go-ahead. Pipeline seam is ready
(`VideoOutputService`; program monitor is the current destination).

## Spec reconciliation (instruction.md) — docs only, no code changed

- `PROMPT-01.md` (was empty): written to freeze as-built Phase 1 scope
  (4 gestures, pipeline, program monitor) + manual sign-off gate.
- `PROMPT-02.md`: cards must render INSIDE composited video via the
  layout-aware `VideoCompositor`; side-by-side clarified as a composition
  mode of the outgoing picture; side panel kept as control view.
- `PROMPT-03.md`: replaced block-highlight + pinch-toggle with pinch-drag
  freeform strokes (underline/highlight/circle), Red/Yellow in-video color
  buttons + UI mirror, colored pointer, per-card undo/redo/clear with
  preservation across card switches. Spotlight demoted to deferred appendix.
- `PROMPT-04.md`: output list updated (laid-out cards, colored pointer,
  annotation strokes); pipeline reframed as extend/finalize; OBS honesty
  rules preserved.
- `AGENTS.md`: compositor bullet extended (layouts, toolbar, pointer,
  strokes) + central canvas principle added; all other rules untouched.
- Conflicts resolved, no prompt file added, no Swift touched. Implementation
  of Phase 2+ awaits user instruction.

## Phase 1 verification (2026-10-27) — automated PASSED

- Scope audit vs `PROMPT-01.md`: single `AVCaptureSession`, Vision hand
  pose, 4 gestures wired end-to-end, mapping persistence (v2 key),
  Show/Hide/Previous/Next + keys, permission/denied/disconnect handling,
  program monitor seam. Zero audio/microphone capture references in code
  (one match is sample-card display text). Zero Phase 2+ code present
  (no pinch/spotlight/annotation/layout).
- Build: `make app` — BUILD SUCCEEDED, 0 Swift warnings. Staged
  `build/GestureCue.app` verified: camera usage description present,
  ad-hoc signature valid (`codesign --verify` OK).
- Tests: `make test` — 48/48 pass, 0 failures (4 router, 13 classifier,
  14 state machine, 9 store, 8 pipeline).
- Phase 2 compatibility: `VideoCompositor` protocol needs no signature
  change — the Phase 2 layout model slots into `ProgramOverlay` and
  `CardOverlayCompositor` reads it under its existing lock; pipeline,
  outputs, gestures, and store stay untouched.
- Checklist fixes: MT-12 example corrected (two fingers is now a listed
  gesture), suite count 38→48, MT-15 includes Previous.
- Blockers: none in automated scope. Awaiting user manual sign-off
  (`docs/MANUAL-TEST-PHASE-01.md`, incl. MT-22 distance diagnostic).

### Phase 1 fix (user testing round 2): program-monitor text missing

- Symptom (screenshot): banner background rendered in Program Output but no
  title/message glyphs. Cause: `NSAttributedString.draw` needs an
  `NSGraphicsContext`, absent on the video queue — glyphs silently dropped.
- Fix: Core Text rendering (`CTLine`/`CTFrame`) directly into the pixel
  buffer; removed the context flip (bottom-origin geometry instead).
- Tests: 50/50 pass, incl. 2 new glyph-pixel regression tests
  (text present → bright pixels; empty card → none). `make app` restaged.

### Phase 1 extension (user testing round 3): card positions

- In-video card position options Bottom/Left/Right (`CardOverlayPosition`,
  segmented control in Camera panel, persisted). Left/Right render a 36%
  side panel; Bottom keeps the lower-third banner.
- Tests: 52/52 pass, incl. 2 new region tests (glyphs on the chosen side,
  opposite side clean). Manual: new MT-23. `make app` restaged.
- Docs: PROMPT-01 scope extended, PROMPT-02 marked presets-done with
  remainder pending, checklist/README/SPEC updated. AGENTS.md unchanged
  (already specifies positioned layouts + canvas principle).

### Phase 1 extension (user testing round 4): expanded output + highlights

- "Expand Output" opens the composited feed in a large second window via a
  second `ProgramOutputPipeline` sharing the compositor (zero cost when
  closed). First slice of the Phase 4 output window.
- Title highlight None/Yellow/Red (persisted, default Yellow): dark-on-marker
  title band in-video at all positions. Yellow/Red match future Phase 3
  annotation colors; independent setting.
- Tests: 56/56 pass, incl. 3 highlight color tests + 1 shared-compositor
  fan-out test. Manual: new MT-24/MT-25. `make app` restaged.
- Docs: PROMPT-01 extended, PROMPT-04 marked window-slice-done, checklist
  (MT-24/25), README/SPEC updated. AGENTS.md unchanged (covered).

### Phase 1 extension (user testing round 5): finger paint

- Replaced automatic title highlight with user finger painting: Paint Mode
  toggle (card gestures suppressed), pinch-drag strokes in Yellow/Red,
  per-card storage, Undo/Redo/Clear, pointer in video. Two-finger pinch
  paints; single index still advances (Presentation mode).
- Removed: title highlight band + its 3 tests (user request).
- Tests: 67/67 (11 new paint controller + 3 stroke/clip/pointer tests).
  Manual: MT-25 rewritten for paint.

### Phase 1 extension (user testing round 6): card pictures

- Cards carry optional picture bytes; Add/Remove Picture via open panel;
  rendered below texts in panel + video (aspect-fit, orientation-correct,
  512px thumbnail cached at overlay time, EXIF-aware).
- Tests: 71/71 (orientation probe + control + 2 store tests). The probe
  caught and fixed an upside-down flip bug (macOS y-up needs no flip).
  Manual: new MT-26. `make app` restaged.

### Phase 1 extension (user testing round 7): hold-to-fire

- Gestures fire only after the same pose is held approximately still ~2 s
  (stillness radius 0.08 normalized units around the run's wrist anchor).
  Motion restarts the hold without re-arming; rapid signing/waving cannot
  fire. Progress meter now tracks the hold clock.
- Tests: 76/76 (14 mechanics tests re-scoped to hold-0 config, 4 new
  hold/stillness tests, 1 anchor test). Manual: hold times updated, MT-27.
- AGENTS.md updated (stillness rule + coverage); PROMPT-01, checklist,
  README, SPEC updated. `make app` restaged.

### Phase 1 tuning (user testing round 8): faster hold

- Hold-to-fire shortened 2.0 s → 1.0 s (user feedback: 2 s felt too slow).
  Stillness gating unchanged: motion still restarts the hold, so signing
  cannot trigger even with the shorter hold.
- Tests: 76/76 (hold-timing tests re-scoped to 1.0 s). `make app` restaged.

### Phase 1 tuning (user testing round 9): closed-fist recognition fix

- Cause: single tip-vs-PIP wrist test misfired on palm-facing fists
  (folded knuckles project tips past PIPs), a strict thumb veto, and
  hard-required thumb joints. Fix: each finger needs BOTH the wrist
  test AND an MCP-reach test to read extended (either curl test firing
  means curled); thumb moved to optional-with-veto (only a clearly
  raised thumb, spread > 1.5, vetoes a fist; missing thumb never blocks).
- Tests: 80/80 (4 new fist regression tests: deep-curl palm-facing
  fist, thumb-across, side-thumb, occluded-thumb; raised-thumb veto
  preserved). `make app` restaged. Manual: re-run MT-08..MT-10.

### Phase 1 tuning (user testing round 10): fist rewrite (occlusion rule) + diagnosis line

- Root cause of on-camera fist misses: the min-over-13-joints confidence
  chain (0.3 per-joint gate, then x0.35 state gate) vetoed real fists whose
  tucked joints are inherently low-confidence. Fix: unseen fingertips now
  count as curled (an extended tip is visible, so an unseen tip is tucked);
  palm skeleton (wrist/MCPs/PIPs) must still be seen clearly, so distant
  hands cannot false-positive; confidence is mean(margins) x mean(quality).
- New live diagnosis line in Gesture Control panel shows per-finger
  verdicts, thumb spread, quality, and rejection reason (or "no hand").
- Tests: 85/85 (5 new: unseen/low-conf tips, skeleton guard, unseen-tip
  reads fist, diagnosis format). `make app` restaged.

### Phase 1 tuning (user testing round 11): reactivity + funny sample pictures

- Reactivity: Vision now reuses one VNSequenceRequestHandler + request
  (temporal tracking, no per-frame rebuild); hold 1.0 s -> 0.5 s, stable
  frames 6 -> 3, cooldown 1.0 s -> 0.5 s, stillness radius 0.08 -> 0.12.
  Anti-signing kept: motion still restarts the hold. Docs/AGENTS/manual
  hold times updated to ~0.5 s.
- Sample cards ship with 4 bundled funny pictures (owl/cat/meerkats/sloth,
  ~50 KB each in Resources/, loaded at startup, degrade to none if
  missing). New test asserts every sample ships a picture; the old
  nil-initial-image assertion was superseded by this requirement.
- Tests: 86/86. `make app` restaged, bundle verified (4 jpgs present).

### Phase 2 lite (user testing round 12): gesture expand/collapse, no mouse drag

- User rejected mouse-drag card layout; positions stay Bottom/Left/Right
  presets. Instead: three-fingers-up gesture (new, completes the 1/2/3
  counting series) toggles fullscreen card expand in the video; same
  gesture collapses back to the stored preset. Expanded text scales 1.6x;
  paint strokes (video-anchored) stay visible while expanded.
- New `CardAction.toggleExpand` (remappable, Expand/Collapse panel button,
  mapping key bumped v2 -> v3 so installs pick up the default).
- Tests: 90/86+4 (three-fingers rule + thumb-ignored, store toggle,
  router default, expanded rect geometry, expanded-vs-collapsed glyph
  pixels). MT-12 updated (three fingers now listed), new MT-28, PROMPT-02
  scope note. `make app` restaged.

### Phase 1 tuning (user testing round 13): card control in Paint Mode

- Paint Mode no longer swallows every card gesture: palm/fist pass through
  (no painting posture resembles them), index-family poses stay painting
  tools and never fire cards (PROMPT-03 S7 pointing-safety preserved).
- Tests: 93/90+3 (new HandGestureDetectorTests gate tests). UI hint,
  MT-25, PROMPT-03 status note updated. `make app` restaged.

### Phase 1 tuning (user testing round 14): mirrored program output

- Painting felt inverted because the preview is mirrored (front camera)
  while the program feed was raw. Fix: the compositor now flips the
  camera frame AND paint coordinates when the camera reports a mirrored
  preview (forwarded via CameraManager to both program branches); card
  layout stays in screen space with readable text. External cameras stay
  raw on both surfaces. (Flipping paint alone would detach strokes from
  the fingertip and break underlining, so video + paint flip together.)
- Tests: 96/93+3 (split-frame mirror/unmirror probes, mirrored paint-dot
  probe). MT-25 mirror expectation added. `make app` restaged.

### Test infra (round 15): build number + auto-restart open

- Painter reported pre-fix mirror behavior after the round-14 restage,
  almost certainly a stale running instance (macOS `open` only focuses
  a running app). Title bar now shows `Build N` (`AppInfo.build`,
  bumped every restage); `make open`/`make run` quit any running
  instance first. No behavior change; tests unaffected.

### Phase 1 audit fixes (round 16): expand shortcut + doc drift

- Audit found one functional mini-gap: Expand/Collapse had no keyboard
  shortcut while every other action did. Added `E` (button + MT-16).
- Doc drift fixed: PROMPT-01 now records five gestures, paint-mode
  palm/fist, 96 tests; manual header scope + suite size updated.
- Tests: 96/96 (no behavior change beyond the shortcut). Build 16
  restaged. Awaiting user manual sign-off (MT-01..MT-28).

## Phase 1 COMPLETE — manual sign-off 2026-10-27

- User signed off Phase 1 on Build 16. Automated: 96/96 XCTest pass.
  Manual: MT-01..MT-28 accepted by tester in chat.
- Phase 2+ unblocked. Recommended next: Phase 4 OBS/Zoom output path
  (chromeless capture window + instructions + presenter controls).

### Phase 4 part 1 (round 17): OBS output path

- Chromeless "GestureCue Output" capture window (borderless, video-only,
  draggable, 1280x720) replaces the titled expanded window; Start/Stop
  Output drives the capture branch + window together (never desynced).
- Presenter controls: 720p/1080p capture resolution (mid-stream switch,
  persisted), mirror override Auto/Mirrored/Original (persisted), live
  status line (state/resolution/mirror). Start disabled until camera runs.
- Docs: `docs/OBS-ZOOM-SETUP.md` (permissions, Window Capture, Virtual
  Camera, Zoom/Teams/Meet, troubleshooting), `docs/MANUAL-TEST-PHASE-04.md`
  (OB-01..OB-09); MT-24 rewritten; PROMPT-04 status updated.
- Tests: 98/96+2 (mirror resolver, resolution presets). Build 17
  restaged. OBS/Zoom end-to-end (OB-08) needs user hardware test.

### Bugfix (round 18): single-instance guard

- User found three GestureCue Dock icons that "cannot close" (copies
  launched from different build folders; red-X closes the window, not
  the app). Fix: second launches now activate the running instance and
  quit (XCTest escape hatch so `make test` never quits under a running
  app). Two instances could never share the webcam anyway.
- Tests: 98/98 (no new automatable surface; manual OB-10 added).
  Build 18 restaged.

### Bugfix follow-up (round 18b): duplicate quit crashed, now clean

- Live verification of the single-instance guard caught a real bug: the
  duplicate used `NSApp.terminate(nil)` before NSApp exists -> SIGTRAP
  crash (exit 133) instead of a clean quit. Fixed with `exit(0)`
  pre-launch (nothing initialized yet: no windows/camera/writes).
- Re-verified live: duplicate direct-exec exits 0 silently, process list
  unchanged (user's instance untouched), `open` reuses the running app.
- Tests: 98/98. Build 19 restaged. Solo launch of the new binary was not
  directly observed (would require stopping the user's instance); the
  solo path is unchanged code (guard early-returns) and the user's next
  `make open` exercises it.

### Feature (round 19): presentation catalog + file import

- Catalog: named decks (create/rename/delete, last protected), card
  authoring (add/remove/edit texts + pictures), picker + Manage sheet,
  JSON persistence in Application Support (seeded from samples once).
  Active deck drives gestures/paint/output; stable card UUIDs keep
  paint strokes across relaunch.
- Import: PDF renders natively (PDFKit, one card per page); PowerPoint
  converts via LibreOffice when installed, else a clear error with the
  PDF workaround. In-video picture cap raised 512 -> 1280px so slide
  text stays legible. Docs: `docs/MANUAL-TEST-LIBRARY.md` (LIB-01..06).
- Tests: 113/98+15 (catalog CRUD/selection/persistence, generated-PDF
  import, missing-file + missing-LibreOffice errors, soffice search).
  Build 20 restaged.

### Bugfix (round 20): slide pictures fill title-only cards

- Imported slides (title + picture, empty message) rendered the picture
  in the bottom 52% with a dead empty band above (user screenshot).
  Cards without message text now give the whole below-title area to the
  picture; cards with text keep the 48/52 split (no regression).
- Tests: 114/113+1 (red-probe picture reaches the ex-message band).
  Build 21 restaged.

### Feature (round 21): slide zoom in/out

- Per-card picture zoom 1x-4x (x1.25 steps, centered, clipped to the
  picture box; zoom out floors at 1x). Session-only like expand state.
  Controls: +/− panel buttons with live % label, +/− keys, and remappable
  Zoom In/Out actions (no default gesture; all five poses are taken).
- Tests: 117/114+3 (zoom clamp/step, per-card isolation, zoomed render
  covers more pixels). MT-16 + LIB-07 added. Build 22 restaged.

### Feature (round 22): one-hand pinch-zoom gesture

- Two-hand idea considered and rejected by user (single-hand pipeline +
  ergonomics + framing); one-hand thumb-index spread/pinch it is.
- PinchZoomTracker: sustained spreading fires zoom-in steps, closing
  fires zoom-out (~6 steps across a full spread, 0.3 s pacing); finger
  motion suppresses static gestures so zooming never flips cards; idle
  re-syncs (no phantom trends). Paint shares pinchGap() math (11 paint
  tests still green, no behavior change). Zoom steps bypass gesture
  mapping (fixed behavior); paint mode owns the pinch (no zoom there).
- Tests: +9 (gap value/nil, spread/close firing, still/jitter silence,
  nil reset, cooldown pacing, suppression linger). UI hint + LIB-07.
  Build 23 restaged.

### Fix (round 23): disambiguate pinch zoom from index commands

- Root cause: the classifier ignores the thumb for index/two/three-finger
  rules, so the zoom hand (thumb+index out) classified as indexUp — spread
  fired zoom steps while a still hold fired "next"; morphing between static
  poses also leaked gap motion into zoom.
- Fix: the thumb is now the mode switch. ZoomHandGate arms zoom only for
  index-extended + rest-curled + thumb raised clear of the palm (height
  >= 0.6 hand sizes, release < 0.5 hysteresis); tucked/hidden thumb always
  means commands. While engaged, the zoom hand never feeds the state
  machine; while disengaged, the tracker is frozen, so static morphs can
  never zoom. Fresh anchor on every engage; full reset on hand loss and
  paint-mode switches. Protocol now vends analyze() (single analysis per
  frame drives both paths). Diagnosis line shows ZOOM while engaged.
- Tests: +12 (gate 7, thumb height 2, hold/reset 3). Build 24 restaged.

### Feature (round 24): "Matteus 6" sample deck in the catalog

- New text-only deck: Matthew 6:1-34 (Swedish, transcribed from the user's
  PDF), one card per verse, no pictures/details. Seeded catalog now holds
  Sample Deck + Matteus 6 (selection stays on Sample Deck).
- Existing installs get it via a one-time seed-revision migration on load
  (seedRevision 1, backward-compatible optional field); the stamp means a
  user-deleted seed deck is never re-added.
- Tests: +3 (deck content, migration adds once, deletion respected);
  updated 4 seed-count assumptions. Build 25 restaged.

### Feature (round 25): command window (signing rest state)

- Problem: signing (fists, palms, brief holds) kept tripping gesture
  commands — same hands carry content and control.
- Fix: rest state is now Signing (cards, zoom, paint ignore hands). A
  still open palm held 2 s, the Listen button, or L opens a 10 s command
  window; fired commands extend it, expiry/End returns to signing. The
  arming palm is release-gated so it never fires its own command.
  Mouse/keyboard actions always work; pause state persists; diagnosis
  shows PAUSED; landmark overlay stays live while paused.
- Tests: +11 (release gate 4, window 4, arm-hold incl. 6 s churn 3).
  Manual PA-01..PA-04 added; MT-08..MT-14 need arming first. Build 26.

### Feature (round 26): thumbs-up replaces fist as Hide command

- User signs with fists constantly, so fist is retired from the default
  commands. New sixth gesture: thumbs-up (four curled + thumb clearly
  raised, reusing the existing fist-veto signal), rare in sign language.
  Defaults: thumbsUp hides, fist unassigned (mapping key bumped v3->v4 so
  installs pick it up; fist stays recognized and re-assignable).
  Sloppy thumbs-up degrades to fist = no action (fail-quiet). Paint gate
  passes thumb like palm/fist. SPEC + MT-09/MT-12 updated. Build 27.

### Fix (round 27): fingertip stillness gate for holds

- Problem: holds only watched the wrist, so a shaking index finger with
  a steady wrist (common in sign language) fired commands.
- Fix: Classification carries fingertip points; the state machine also
  requires tips to stay within 0.08 of run anchors measured relative to
  the wrist (sway cancels, articulation counts). Finger motion restarts
  the hold like wrist motion; unseen tips skipped, newly seen adopted.
  Applies to command holds and 2 s palm arming alike.
- Tests: +7 (shake never fires, steady/sway/adopt/vanish/no-anchor fire
  correctly, tips plumbing). Build 28 restaged.

### Feature (round 28): thumb-left/right commands + thumbs-up fix

- Thumbs-up was unreliable: the radial tip-to-pinky spread barely
  separates tucked from raised thumbs, so frames flickered fist/thumb
  and holds never completed. Replaced with an axial/lateral thumb model
  (tip past knuckles along/across the hand axis, hand-size units):
  axial>=0.45 rising = thumbs-up, lateral>=0.45 sideways = thumbLeft/
  Right (raw view is unmirrored: image-right = user's left), else fist.
  Diagnosis line shows axial/lateral for live tuning.
- New defaults (v5 supersede): thumbRight next, thumbLeft previous;
  indexUp/twoFingersUp join fist as unassigned (all occur in signing).
  Paint gate passes thumb poses. MT-10/MT-20/PA-03/MT-25 + SPEC updated.
- Tests: +3 (left/right/diagonal; up rewritten with axis values). Build 29.

### Fix (round 29): stillness gate tracks extended tips only

- Thumb poses (all curled) never completed holds: the round-27 tip gate
  tracked wobbling tucked-tip estimates, restarting every frame. Now the
  classifier only reports tips for extended fingers; curled/unseen are
  nil and skipped. Shaking-index protection preserved (extended tip
  still tracked); fist-family holds rely on the wrist again.
- Tests: +1 (curled excluded, extended index included). Build 30.

### Fix (round 30): listening state visible in program feed

- "Works then stops": the 10 s window expired silently — countdown only
  in the control panel, invisible while presenting. Now the feed burns a
  corner dot while listening (green, amber under 5 s; gone when signing),
  in the monitor, output window, and OBS alike. Window 10->20 s with a
  60 s hard cap (in-window fires extend, so a forgotten window still dies).
  Overlay re-syncs only on dot transitions, not every tick.
- Tests: +4 (dot rect/colors/composite presence+absence, max-open cap);
  3 window-timing tests moved to 20 s. Build 31 restaged.

### Fix (round 31): listening latches instead of expiring

- User confirmed the window died mid-commanding. Timed windows (and the
  60 s cap, which killed even continuous use) are replaced by a latch:
  palm-hold/button/L latches listening ON; fist-hold 2 s/Stop/L ends it;
  5 idle minutes release it automatically. Each command refreshes idle.
  Dot stays green, amber in the last idle minute; panel shows M:SS idle.
- Tests: window suite rewritten for latch semantics (default 300,
  sustained-use-never-expires replaces the cap test); dot threshold test
  moved to 60 s. Build 32 restaged.

### Feature (round 32): record program feed to MP4

- Video-only MP4 (no mic, per privacy rule) via AVAssetWriter H.264,
  tapped permanently off the program pipeline (nil-check/frame when
  idle). First frame fixes encode size; mismatches dropped + counted.
  Source PTS preserved; record auto-saves timestamped files to
  Movies/GestureCue; UI shows elapsed, saved-file reveal, drop count,
  errors. Recording force-enables the program branch (restored after)
  and auto-stops if the camera stops. R shortcut.
- Tests: +4 (real encode to temp MP4, cancel-no-frames, double-start,
  mismatch drops). Manual REC-01..03 in Phase 4 doc. Build 33 restaged.

### Fix (round 32b): recorder append made synchronous

- Async appends raced stop(): the finishing flag flipped before queued
  tail frames executed, so frames vanished uncounted (testMismatch:
  0 drops) and bursts saturated the encoder (testRecords: 22 drops).
  Sync append serializes callers with the encoder queue; tests pace
  frames like the 30 fps pipeline. No deadlock: recorder queue never
  re-enters append (documented: not from onFinish).

### Session handoff (Build 33, 2026-10-28)

- Long-session consolidation: current state now lives in AGENTS.md
  ("Current state" section). Chat history is no longer source of truth.
- Resume recipe: read AGENTS.md, then SPEC.md, then PROGRESS.md tail.
  Verify with `make test` (unsandboxed) + `make app` + codesign verify;
  launch with `make open`. Manual checklists in docs/.
- Next: virtual camera / Phase 2 leftovers / AI cards (see AGENTS.md),
  or user-reported frictions from real services.
- Housekeeping: no git repo exists. Recommend `git init` + first commit
  so resume never depends on one live working copy.

### Repo (2026-10-28): git init + first public checkin

- `main`, root commit 4a6b30b, 57 files. Ignored: prompts/,
  instruction.md, old-ignore/, generated_images/, build/, coverage
  artifacts, Xcode user state. Secrets grep clean. README refreshed
  from milestone-1 staleness (v5 gestures, latch, catalog, recording).

### Scope (branch virtual-camera, 2026-10-28): native virtual camera

- Path: CoreMediaIO Camera Extension (Swift CMIOExtensionProvider/
  Device/Stream sources) embedded in the app + host activation UI.
  App streams IOSurface-backed composited buffers to the extension
  (pool already IOSurface-backed). DAL plugins are dead (removed
  macOS 15) — extension is the only viable route.
- References: Apple "Creating a camera extension" doc, OBS PR #7777,
  petehaughie/cameraextension, m96-chan/virtualcamera4mac.
- BLOCKER QUESTION: extension loading requires validated signing —
  outside the App Store that means Developer ID + notarization (paid
  Apple account); ad-hoc will not activate, and the
  `systemextensionsctl developer` shortcut needs SIP disabled.
  Recommended next step if no paid account: minimal feasibility spike
  (skeleton extension + activation attempt) before full build.
- Entitlements: system-extension.install (host) + camera-extension
  (extension); user enables once in System Settings (like OBS dance).

## Branch virtual-camera — Build 34 (2026-10-28 session)

Native CoreMediaIO virtual camera ("GestureCue Camera", 720p) implemented, all
automated checks green. Manual activation (VC-01..07 in docs/VIRTUAL-CAMERA-SETUP.md)
is the user's job: copy to /Applications, Enable, approve, reboot if asked.

- Extension: GestureCueCameraExtension/ (provider/device/source+sink streams,
  Info.plist, entitlements) wired as PBXNativeTarget + Embed System Extensions.
- Host: SystemExtensionManager.swift (activation), VirtualCameraService.swift
  (sink transport + 720p scaler + service), AppViewModel pipeline + status,
  CameraPanelView Virtual Camera section.
- Signing: Automatic, team X8YHS47G23; staged app passes codesign --verify --deep.
- Tests: 179/179 pass incl. 6 new VirtualCameraServiceTests (drop/scale/passthrough/stop).
- Build fixes this session: product filename = target name (not bundle ID),
  embed via absolute $(BUILT_PRODUCTS_DIR)/$(SYSTEM_EXTENSIONS_FOLDER_PATH)
  (dstSubfolderSpec 16 silently skipped), transportType Int 'virt', CoreText
  placeholder keys (no AppKit in appex), withLock shadow rename.
- NOT done: hardware activation verify, thumb-direction verify (carried over),
  commit/push of this branch (left uncommitted for review).
- Build 34 fix: embeddedExtensionIdentifier used a relative URL (FileManager
  resolved it against $PWD, always "not found"). Now absolute via
  bundleURL.appendingPathComponent. Build number bumped 33 -> 34.
- Build 35 fix (real cause of "extension not found"): source Info.plist lacked
  CFBundleIdentifier/Executable/Name/Version keys, so Bundle.bundleIdentifier
  was nil. Added with $(...) build-setting expansion; verified built plist
  resolves to com.gesturecue.app.cameraextension. Build 34's relative-URL fix
  was also required. Build number 35.
- Build 36 pending: app needs CODE_SIGN_ENTITLEMENTS (system-extension.install)
  + provisioning profile. Blocked: Mac not registered in developer account.
  Makefile now passes -allowProvisioningUpdates. Next: user builds once in
  Xcode GUI to register the Mac, then `make app` works headless again.

## Session end 2026-10-29 — resume checklist (branch virtual-camera, Build 36)

State: extension + host + UI + 179 tests done; staged app deep-verified.
AGENTS.md has a RESUME HERE section; setup doc troubleshooting updated.
Work is UNCOMMITTED (7 modified incl. AGENTS.md/PROGRESS.md, 5 new).

1. User: open GestureCue.xcodeproj in Xcode, ⌘B, accept Mac registration.
2. Muse: `make app` unsandboxed, verify entitlement in signature.
3. User: quit app, cp -R build/GestureCue.app /Applications/, check Build 36+ title.
4. User: Enable Camera -> approve in System Settings -> reboot if asked -> VC-01..07.
5. Commit + push branch (ask first), then verify "GestureCue Camera" in Zoom.

## 2026-10-29 — provisioning blocked on PLA acceptance

`make app` (Build 36, unsandboxed) fails: "PLA Update available: agree to the
latest Program License Agreement in your developer account", hence no profile
for com.gesturecue.app. User steps: (1) accept PLA at developer.apple.com,
(2) Xcode GUI ⌘B to register the Mac, (3) tell Muse to rebuild. Build 35 on
the user's machine still shows "Missing entitlement" — expected, it predates
the CODE_SIGN_ENTITLEMENTS fix. README gained a Virtual Camera section.

## 2026-10-29 — Build 36 staged, blocker cleared

User accepted PLA + built once in Xcode GUI (Build Succeeded 14:37, Mac
registered). Headless `make app` now succeeds: entitlement
com.apple.developer.system-extension.install present in signature,
codesign --deep OK. Xcode touched only the scheme version (1.7->1.8).
Next: user re-copies to /Applications, checks Build 36 title, Enable ->
approve -> reboot if asked -> VC-01..07.

## 2026-10-29 — Build 37: activation-matching fixes (OBS reference)

System error was "Extension not found in App bundle / unable to find any
matched extension". Diffed OBS's working camera extension on this Mac:
wrapper filename, executable, CFBundleName must equal CFBundleIdentifier,
and CFBundlePackageType=SYSX is required, else sysextd won't match.
Fixed: PRODUCT_NAME=com.gesturecue.app.cameraextension, SYSX added,
mach service corrected to team+extension ID. Build succeeds, deep OK.

## 2026-10-29 — Build 38: app-group fix for "extension category returned error"

Activation reached sysextd (Build 37) but CMIO delegate rejected it:
log showed validating_by_category -> uninstalling. Cause (confirmed by
OBS on this Mac + independent reports): CMIOExtensionMachServiceName must
be prefixed by one of the extension's App Groups; ours declared none.
Fix: application-groups X8YHS47G23.com.gesturecue.app in both extension
and host entitlements (mach name already group-prefixed, unchanged).
Staged, groups verified in both signatures, deep OK.

## 2026-10-29 — Build 39: sink discovery hardening + frame-path logging

Zoom showed the slate (upside down): extension runs, host frames never
arrive. Suspects: UID-based device match, source/sink order guessing.
Fixes: device matched by CMIO object name (AVFoundation/UID path dropped),
sink picked by controlled stream name (never falls through to source),
sample duration 1/30 added, os_log on host connect/send and extension
start/forward, slate text un-flipped. Extension CFBundleVersion 1->2 so
macOS restages it. Staged sandboxed (cached profile), deep OK.
Unit tests not re-run (need unsandboxed shell; change is hardware-path-only).

## 2026-10-29 — Build 40: discovery diagnostics + UID fallback + stable IDs

Host log proved findDevice never sees the device ("not present" every
retry) while Zoom does. Build 40: guaranteed-correct buffer-pointer
reads, scan logging (count + all names), AVFoundation cross-check dump,
UID fallback path restored, stable device/stream UUIDs, extension v3.
Sandboxed swiftc probe was inconclusive (HAL blocked in sandbox).
Next: user reboots (clears v1-pending flux), re-copies, Build 40, Enable,
Zoom check, paste frame-path log tail if still slate.

## 2026-10-29 — Build 41: virtual-camera scaler cropped 1080p (Zoom card cut)

User report (post-reboot, activation live): in-app Video output shows the
full card, but Zoom shows the card cut/cropped — same moment, mirror off,
live hide/show/next all working. Root cause in
`VirtualCameraFrameScaler.scaleToCameraSize`: `CIContext.render(_:to:bounds:)`
treats `bounds` as a source region, not a scale, so 1080p captures were
sent as a bottom-left 1280x720 crop (top 360 px incl. card title + right
640 px dropped). Fix: shrink the full frame with an affine transform
before rendering (16:9 sources, no distortion). Regression test
`test1080pScalePreservesFullFrame` (edge-marker bands) failed before
(top+right edges dropped), passes after. Touched file left warning-free
(.external rename, discarded buffer-pointer results, explicit CFString
pointer formation — same runtime behavior). Suite: 180/180 green
(unsandboxed). Build 40->41, staged, deep codesign OK, extension embedded.
Next: user re-copies to /Applications, checks Build 41 title, Enable,
Zoom verify full card at 1080p and 720p (720p was always passthrough).
Outcome: Enable after re-copy went Live with NO reboot (v2
`waiting to uninstall` line is harmless while v3 is active). Host-only
updates = `make reinstall` + Enable, documented in
docs/VIRTUAL-CAMERA-SETUP.md; reboot only on extension version bumps.

## 2026-10-29 — Build 42: Uninstall reachability + honest Live label

CORRECTION to the Build 41 outcome: "Live" only meant the activation
handshake succeeded — the v3 process never launched (pgrep empty, no
device in QuickTime/Zoom/CMIO/AVFoundation) while v2 sat `waiting to
uninstall on reboot`. The `systemextensionsctl uninstall` CLI is SIP-
blocked, and the in-app Uninstall button hid itself exactly in the
"Not installed" state where it was the only reset path. Fixes:
Uninstall always shown except mid-removal; new `isSinkConnected`
flag + 1 s ticker so the panel reads "waiting for the camera device"
until frames truly flow, then flips to Live on its own. Tests:
182/182 green (2 new sink-connected tests). Staged, deep OK.
Next: user installs Build 42, Uninstall (now visible) → Enable;
if v3 still won't launch, reboot (pending v2 clears at boot).

## 2026-10-29 — Build 43: wider stable capture (1080p default, Center Stage off)

User compared Zoom screenshots: virtual feed (ours, 16:9 exact) frames
tighter than Zoom-driving-built-in-direct. Root cause is source FOV, not
stretch: the 720p preset center-crops the 12MP sensor, and Center Stage
auto-tracking drifts the presenter against the burned-in cards. Fix:
capture defaults to 1080p (wider sensor window, clean downscale to the
720p outputs); Center Stage forced off under exclusive app control
(`centerStageControlMode = .app`, restored to `.user` on stop) for a
fixed presenting frame. Also fixed: persisted resolution was never
pushed on start (every launch silently fell back until re-toggle).
Tests: 184/184 green (2 new default/preset guards; Center Stage path is
hardware-bound). Staged, deep OK. API note: the Center Stage switch is
the class-level `AVCaptureDevice.centerStageControlMode` /
`.isCenterStageEnabled` (12.3+), not per-device members.
Next: user installs Build 43, toggles Resolution to 1080p once
(persisted 720p needs one manual switch), verifies wider stable framing
+ hands in frame while signing, gestures still fire, Zoom full card.

## 2026-10-29 — Build 44: configurable trigger timing (user request)

New "Trigger Timing" slider in Gesture Control: command hold-to-fire
0.2–2.0 s in 0.1 steps, readout in seconds + ms, persisted, applied
live (mid-hold changes reset stability). Default stays 0.5 s; 2 s
arming clutch and cooldown stay fixed safety behavior. Plumbing:
`HandGestureDetector.setHoldDuration` → state machine config.
Tests: 186/186 green (default-0.5 guard + 1.5 s custom-hold firing
test). Staged, deep OK. On-camera feel (slider → fire timing) needs
user verification.
Next: user installs Build 44, drags slider, confirms fire timing
follows; then commit + push Builds 43–44 (ask), VC-01..07, merge.

## 2026-10-29 — Build 45: two-finger fading brush (user request)

Index + middle extended (ring/pinky curled, any thumb) now paints
freehand strokes on the visible card that fade out ~1.5 s after release
instead of persisting — any stroke direction, nothing remains. Works in
any mode without entering paint mode; uses the shared paint color.
Middle-extended discriminates from zoom (needs it curled), so the two
can never engage together; while brushing, the resembling two-finger
command is suppressed. Strokes clear on card/mode switch (no leaking
onto another card); expired ones pruned per frame, fade computed at
draw time so no frame churn. Tests: 199/199 green (9 brush engage/draw/
fade/prune/exclusion + 4 fade-curve). Staged, deep OK. On-camera feel
(engage reliability, fade speed) needs user verification.
Next: user installs Build 45, brushes over card text/pictures,
confirms strokes appear + vanish; then commit + push 43–45 (ask).

## Session end 2026-10-29 — virtual camera shipped (Build 45, all verified)

User verified on camera: full card in Zoom at 720p + 1080p, wider
stable framing, trigger-timing slider feel, fading brush (appears +
vanishes). Committed 3ccca10 ("Framing, trigger timing, fading brush"),
pushed branch `virtual-camera`, tag `virtual-camera-build-45` (joins
`virtual-camera-works` on Build 42). Tree clean. Motion-gesture
triggers explicitly DEFERRED by user (advised against: signing is
motion). Resume: VC-01..07 checklist → merge to main (ask) → optional
HAL-refresh improvement. AGENTS.md holds the resume state; this log
holds the round-by-round evidence above.

## Session end 2026-10-29 — reboot + resume checklist (branch virtual-camera, Build 40)

State: activation LIVE since Build 38; host-to-sink frames not yet flowing
(host scan empty while Zoom sees the device). Build 40 staged with scan
logging, UID fallback, stable IDs, extension v3. Work UNCOMMITTED.
AGENTS.md has the current resume section; README troubleshooting is current.

1. User: reboot the Mac (clears v1 "waiting to uninstall on reboot").
2. User: quit app, cp -R build/GestureCue.app /Applications/, check Build 40.
3. User: Enable Camera (re-approve if asked), restart Zoom, select camera.
4. If live video: run VC-03/04/06/07. If slate: paste frame-path log tail,
   Muse diagnoses from scan/AV/UID lines. Then commit + push branch (ask).
