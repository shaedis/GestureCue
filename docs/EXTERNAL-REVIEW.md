# GestureCue — External Review Brief (Build 82)

> HOW TO USE: paste this whole document to the judging model, ideally with
> read access to the repo at `main` (published, tag `main-build-82`).
> Everything below shipped on branch `visual-pedagogy` (Builds 46–82)
> and merged. Earlier milestones tagged `virtual-camera-works`,
> `virtual-camera-build-45`, `visual-pedagogy-build-71/76/82`.
> Build 83 (Live Card composer + split layout + live subtitles) is
> UNMERGED on branch `live-generation` — see the §4 tail and the
> marked notes; judge it as in-progress, not shipped.
> The judging ask is at the bottom.

## 1. What this is

GestureCue is a native macOS SwiftUI app that lets a presenter control
accessible on-video presentation cards with webcam hand gestures. The
target user signs (sign language) while presenting over Zoom/Teams: hand
input is ignored by default and only acts inside an explicitly armed
command window, so normal signing never triggers actions.

- Stack: Swift 6, SwiftUI, AVFoundation (capture), Apple Vision
  (`VNDetectHumanHandPoseRequest`), AppKit only for window needs.
- Zero third-party dependencies. All camera processing on-device.
- Privacy: camera only (`NSCameraUsageDescription` set), video processed
  live and never stored or uploaded — except user-initiated local MP4s.
  Microphone is never requested. Exception: the AI Studio sends ONLY
  user-approved documents (never webcam frames) to the Meta Model API;
  the API key lives in the Keychain and per-source approval gates every
  network call.
- Repo: Xcode project + Makefile (`make build|test|app|run|open|clean`),
  XCTest suite (365 tests), docs + manual checklists in `docs/`.

## 2. Architecture (as claimed)

- One shared `VideoCaptureService` (720p/1080p selectable, 1080p default,
  Center Stage auto-tracking forced off) fans frames out to
  `VideoFrameConsumer`s: `HandGestureDetector` (Vision analysis) and
  program-output branches (`VideoCompositor` → `VideoOutputService`).
- Gesture path: `HandPoseDetector` → `GestureClassifier` (geometric,
  normalized landmark space, resolution-independent) →
  `GestureStateMachine` (stability + stillness-gated hold-to-fire +
  cooldown/debounce) → `GestureActionRouter` (user mapping) → card store.
- Command listening latches: rest state ignores hands; still open palm
  (2 s) / Listen button / L arms, still fist (2 s) / Stop / L ends,
  5 idle minutes auto-end (any user activity — fired commands, zoom
  steps, paint/brush strokes — refreshes the deadline). A corner dot
  is burned into the program feed while listening (green, amber in
  the last minute).
- Video path: `CardOverlayCompositor` renders camera + card layouts +
  pointer + paint/brush strokes into pooled pixel buffers (target
  1280×720 @ 30); fading brush strokes snap to lines/ellipses on
  release (`BrushShapeClassifier`, aspect-uniform geometry) and paint
  an adaptive legibility halo (contrast-triggered, polarity-aware,
  per-segment). Destinations behind a `VideoOutputService` protocol:
  in-app program monitor, OBS capture window, MP4 recorder
  (Movies/GestureCue, H.264, video-only), and the native virtual camera.
- Virtual camera: CoreMediaIO camera extension (own target, embedded
  `.systemextension`) publishing device "GestureCue Camera" with a
  source stream (720p out to Zoom/Teams) and a sink stream (host app
  enqueues composited frames; no custom XPC). Fixed 720p BGRA; host
  scales (passthrough at 720p); send-side drops, never blocks.
- Cards persist as JSON in Application Support (seeded once from bundled
  samples); stable UUIDs keep paint strokes across relaunch. Decks carry
  an optional collection tag ("History", "Bible", …).
- AI Studio (`GestureCue/AI/`, own single window): source import
  (paste, PDF, PowerPoint via a dependency-free zip+XML reader,
  Markdown/TXT, Jupyter-as-data, AI-generated decks as source) →
  settings → Muse Spark lesson plan → per-card artwork → editable
  drafts → approved lessons saved to the catalog and presented over
  the existing video/virtual-camera/MP4 pipeline. Backend behind a
  `GenerationService` protocol with a mockable `HTTPTransport`;
  orchestration in a `LessonGenerator` actor with progress +
  cancellation.
- Generation fidelity: freeform sources (paste/text/decks) plan
  creative illustrated lessons (deterministic local diagrams preferred
  for exact content, else Muse Image illustration composed with title
  + labels); presentation imports (PDF/PowerPoint) plan faithful
  verbatim splits (quote/near-quote, order-preserving, empty art
  prompts, null diagrams, temperature 0.1) that ship with the author's
  original images reattached and no image API calls.
- Studio workspace integrity: dirty tracking across source/drafts/
  title; New and new-source imports over unsaved drafts raise
  Save/Discard/Cancel; adopting new source clears stale drafts and
  cancels running generation; deck menus list AI Studio decks only
  (illustration-prompt provenance); re-imported decks round-trip
  artwork + prompts with per-card dirty markers and regenerate-changed
  semantics.
- Window lifecycle: closing the main window dismisses the Studio and
  stops recording/output/capture/virtual stream (drafts survive in
  memory); the app stays running for Dock-click reopen.
- Concurrency: Vision/gesture work off main thread, UI published on the
  main actor. Protocols + DI for classification/routing/generation for
  testability.

## 3. Feature inventory (as claimed working, user-verified on camera — see §5)

- 8 gestures: palm, fist, thumbs-up, thumb-left/right, index / two- /
  three-finger. Defaults (mapping v5): palm→show, thumbs-up→hide,
  thumb-right→next, thumb-left→previous, three-fingers→expand;
  fist/index/two-fingers unassigned (occur in signing).
- Configurable trigger timing: hold-to-fire 0.2–2.0 s slider (default
  0.5 s), persisted, applied live.
- Presentations: catalog (create/rename/delete), PDF + PowerPoint
  (.pptx/.ppt/.ppsx via LibreOffice) import as slide cards.
- Card layout: bottom/left/right presets, fullscreen expand, pinch zoom
  on pictures (up to 4×), per-card pictures. Video + Card mode places
  the card panel left/right/bottom with the whole camera aspect-fit in
  the opposite tile (persisted "Card panel" picker).
- Finger paint mode: pinch thumb+index to draw persistent per-card
  strokes (Yellow/Red, undo/redo/clear); index-family gestures
  suppressed while painting.
- Two-finger brush (index+middle): freehand strokes that fade ~1.5 s
  after release; zoom-exclusive by finger pattern; resembling command
  suppressed while brushing; cleared on card/mode switch. Straight
  drags snap to clean horizontal/vertical lines and closed loops to
  ellipses on release (diagonals/scribbles stay freehand); an adaptive
  halo under the fading line keeps strokes legible over busy photos
  and white diagrams. Paint/brush activity keeps the command window
  alive. Persisted on/off toggles for the brush and pinch zoom.
  (Mouse brush on the program monitor was implemented but is
  parked unverified as a future feature — see §6.)
- Outputs: program monitor, OBS window, MP4 recording, native virtual
  camera with activation UI (Enable/Stop/Uninstall, approval + reboot
  guidance, honest Live/waiting status via sink-connectivity ticker).
- Card fit for lessons: bottom banners with artwork split side-by-side
  (text left, picture right); message type shrinks to fit instead of
  clipping; titles wrap to 3 lines on narrow panels; AI prompts
  constrain lengths and split overlong concepts across cards.
- AI Studio: import (paste, PDF, PowerPoint, Markdown/TXT, notebooks,
  AI decks), lesson settings (audience/level/subject/style/language/
  cards, optional AI Instructions), Keychain key entry, per-source
  approval-gated generation with progress + cancel, editable drafts
  (texts, labels, prompt editing, regenerate/remove with per-card
  progress), save to catalog collections (model-suggested, persisted).
  Subjects include Bible / Religious (verse word-for-word rule).
  Adult audiences get respectful adult prose (no defining common
  knowledge); importing a picture deck/PDF reattaches the author's
  original images to the generated cards.
- Studio workspace: New with ask-to-save; imports clear stale drafts
  (guarded when unsaved); deck menus offer AI Studio decks only;
  "Edit Existing Deck…" round-trips artwork + prompts with per-card
  edited markers, "Regenerate Changed" refreshes only edited prompts,
  "Refresh Text" re-composes wording free; single Studio window
  (repeat opens focus it).
- Faithful presentation mode: PDF/PowerPoint imports split the
  author's pages/slides verbatim into cards with the original images
  reattached — no rewritten text, no new illustrations/diagrams, no
  image API cost; Studio shows a faithful-mode caption.
- Accessibility UI: large text, contrast, VoiceOver labels, visible
  status; no sound dependence. Mouse/keyboard actions always work.

## 4. Recent work (Builds 36–83)

- 36–40: extension target, provisioning (team X8YHS47G23), activation,
  sink discovery hardening, stable device/stream UUIDs, diagnostics.
- 41: FIX — 1080p scaler cropped instead of scaling (`bounds` is a
  source region); full-frame affine scale + regression test.
- 42: FIX — Uninstall button hidden exactly when needed; Live label now
  reflects real sink connectivity (1 s ticker).
- 43: 1080p capture default (wider FOV), Center Stage off (stable
  frame), persisted resolution actually pushed on start (was dropped).
- 44: trigger-timing slider. 45: fading brush. Merged to `main`.
- 46–47: AI foundation + Studio + diagram renderer on branch
  `visual-pedagogy`: Meta API client, Keychain/in-memory
  credential stores, 4-kind diagram renderer, illustration composer,
  generator actor, Studio window. Live-verified both API endpoints
  (Spark envelope matches parser; ~150+ reasoning tokens precede
  content; images are decodable WebP) and Spark's plan-JSON shape
  (prompt pins the diagram-kind catalog after the model invented kinds).
- 48: FIX — Studio drafts wiped on main-window changes (view model now
  App-owned).
- 49: lesson card fit + Bible subject.
- 50: deck round-trip — "Edit Existing Deck…" re-imports with
  artwork+prompts; cards persist prompt + raw base image; per-draft
  prompt editing with dirty marker; "Regenerate Changed" refreshes only
  edited prompts; "Refresh Text" re-composes base art free.
- 51: FIX (found by live E2E review) — the composer's title band covered
  diagram edge labels (e.g. "2/4 = 1/2"): diagrams now ship raw, and the
  card schema carries `diagramKind` so re-imported diagrams still skip
  the band; FIX — in-flight cancellation surfaced as a network error
  (CancellationError now passes through unwrapped).
- 52: approval tick resets when source text/title edited (ST-02 edge).
- 53: card titles wrap to 3 lines on narrow panels (were truncated).
- 54: fix-issues.md — single Studio window; New + ask-to-save with
  dirty tracking; Studio deck menus list AI decks only (prompt
  provenance); generate() re-checks cancellation before assigning.
- 55: imports clear stale drafts; guarded import confirmation over
  unsaved drafts; adopt() cancels running generation.
- 56: main-window close dismisses Studio and stops recording, output,
  camera, and the virtual stream (drafts survive in memory).
- 57: faithful presentation splits (verbatim prompt, temp 0.1, no new
  art; live-verified 3/3) + native .pptx/.ppsx text extraction.
- 58: release gate — PPTX security caps + 9 tests; strict plan schema
  (enforcement proven live) + timeout/retry/messages; explicit mode
  picker + measured fidelity verdicts; zero warnings.
- 59: "Diverse" collection. 60: card "N/M" corner badge on video.
- 61: model-suggested collections (existing match or persisted new
  bucket; approval-gated; live-verified).
- 62: Video + Card side-by-side position (whole camera aspect-fit in
  a left tile beside the card; mirror-aware; hidden/expanded stay
  fullscreen).
- 63: PowerPoint original images reattached (slide rels → media;
  [Image N] markers → plan imageRefs → per-card originals; strict
  schema + prompt assignment live-probed).
- 64: PDF original images (CGPDF XObject walk; JPEG verbatim, other
  Quartz-decodable streams to validated PNG; nested Forms; image-only
  pages survive).
- 65: optional AI Instructions field (blank = identical default;
  provided = labelled, subordinated guidance block; saved per deck,
  restored on edit; live-probed on the Sputnik acceptance).
- 66: save flashes green "Saved" then closes the Studio window.
- 67: adult prose for adult audiences (beginner respects general
  knowledge; adult-prose rule; children unchanged; live-probed).
- 68: Video + Card tile placement (video left/right/bottom; top panel
  side-splits; persisted).
- 69: fewer-cards confirmation (source segments outnumber Cards →
  Generate/Cancel alert).
- 70: reframed as card placement (Card panel Left/Right/Bottom;
  video opposite/top); default keeps previous visuals.
- 71: per-card regeneration spinner + button disabling.
- 72: brush shape snapping on release (`BrushShapeClassifier`, no ML;
  14 tests).
- 73: FIX (user report: brush "not recorded" over images in Zoom) —
  lab-verified the stroke IS composited and encoder-preserved over
  photos, diagnosed a contrast/visibility failure, and added a dark
  legibility halo under fading brush strokes (same fade curve;
  committed strokes unchanged; 2 tests). SUPERSEDED by 75's adaptive
  halo — judge the Build 75 design, not this one.
- 74: FIX (brush "stopped" mid-session) — paint/brush activity now
  refreshes the 5-minute command window (was: fired commands only);
  mouse brush implemented (press-drag-release, same fade/snap
  semantics, works paused; 14 tests) — parked unverified in 76.
- 75: FIX (brush invisible on white diagrams) — the fixed dark halo
  blinded yellow mid-fade and muddied red-on-white; halos are now
  per-segment adaptive (sampled-bg trigger, away-from-line polarity,
  linger-into-fade curve; 6 halo tests).
- 76: mouse brush parked as a future feature (no crosshair on-site,
  cause undetermined, user chose to skip debugging); on-screen
  promise removed, code stays inert and tested, spec filed in
  `docs/PENDING-FEATURES.md`.
- 77: first custom app icon (asset catalog, 16–1024). 78: card cap
  10 → 30. 79: pinch-zoom on/off toggle. 80: two-finger brush on/off
  toggle (2 tests). 81: duplicate AI-deck menus merged into one.
  82: output labels renamed (Program Monitor, Fullscreen Window,
  Open/Close Window).
- 83 (UNMERGED, branch `live-generation`): Live Card composer under
  the Presentation panel — prompt → single-card plan
  (`planSingleCard`, strict 1-card schema) + one illustration,
  text/picture/both modes, 6 art-style presets, Return generates;
  generated cards append + show live (Bottom flips to Left);
  multi-line live typing renders as a transient subtitle overlay
  (dynamic height, lifts above bottom cards, sits beside side
  cards, adjustable size/colors, deck untouched). Split Text +
  Picture position: subtitle text strip + side picture panel
  (aspect-cover art, aspect-fit diagrams, textless cards go
  full-height panel with no strip); side presets also cover
  non-diagram art. Paint clips to both split halves. 38 new tests.
- Test count grew 179 → 403 across these builds, suite green throughout
  (`xcodebuild test`), staged apps deep-codesign-verified.

## 5. Verification status (as claimed)

- Automated: 403/403 XCTest green (365 on `main`, +38 on branch
  `live-generation`) — classifier geometry, thresholds,
  stabilization, cooldown/debounce, stillness gating, mapping, card
  transitions, paint/brush/fade math, brush toggle, brush
  shape-snapping, adaptive
  halo (deterministic fixtures; trigger/polarity/linger matrix),
  mouse brush lifecycle + monitor mapping (crop/mirror/clamp),
  compositing, layout/fit helpers, title wrapping, split/side
  cover geometry + subtitle overlay geometry/renders, live-card
  composer + single-card schema + art presets, virtual-camera
  service/scaler, AI client/importer/diagrams/generator/round-trip/
  fidelity/provenance, PPTX extraction (embedded fixture), PPTX/PDF
  image extraction (hand-built fixtures, pixel-exact asserts), PDF
  kind routing (mocked transport; no network in tests).
- Manual (user, on camera): gestures fire, listening latch (incl.
  staying alive while brushing), paint, brush shapes + fade +
  legibility over photos/diagrams, Zoom + QuickTime show full card
  at both resolutions, enable/disable/uninstall flows.
- AI Studio live E2E (real API, Build 50 code, temp probe since
  removed): history lesson (5 cards, 4 generated illustrations +
  timeline; all dates/facts faithful to source, chronology correct)
  and fractions lesson (5 cards, all diagrams; 2/4 = 1/2 and
  1/2 + 1/4 = 3/4 correct) generated through the real
  LessonGenerator → composer → card → compositor chain; composited
  1280×720 frames reviewed for readability (no clipping, full text,
  banner clears the signing area) plus 320px small-tile simulation.
  This review caught the Build 51 diagram-band defect (fixed).
- Build 83 gate ST-17 (live composer + subtitles) and ST-18 (split
  layout) are written but UNVERIFIED — unticked boxes on branch
  `live-generation`; no automated test substitutes for the user's
  on-camera run.
- Faithful-mode live check (real API, exact Build 57 prompt): 3/3
  cards verbatim from slide-style source, empty art prompts, null
  diagrams. Full in-app faithful run covered by flow P (user-checked).
- Studio manual gate: ALL RUN — user reports ST-01..15 pass on the
  Build 82 Studio (key round-trip, import, in-app generate/review/
  save, present over Zoom, gestures, brush shapes, brush legibility
  over photos + white diagrams, window-alive-while-brushing,
  cancel), plus flows H/F/P end to end. ST-16 mouse brush is parked
  with the feature (not runnable).
  fix-issues.md items (single window, New+ask-to-save, AI-only
  menus, stale-draft clearing, main-close behavior) user-verified.
- Formal VC-01..07 manual checklist: ALL RUN — user reports pass
  (clean-state enable through uninstall).
- Hardware/network-bound paths (real CMIO sink, Center Stage switch,
  live plan/image calls, Keychain roundtrip) have no unit tests by
  nature; covered by manual verification + one-off live probes only.

## 6. Known caveats / open items (as claimed)

- Thumb left/right directions derived from code, never hardware-verified
  as a pair.
- Fresh-staged extension device needs an app restart before the host
  scan sees it (stale per-process HAL view); QuickTime/Zoom see it
  immediately. No in-code refresh yet.
- Old `waiting to uninstall on reboot` extension generations block
  fresh launches; they clear at reboot. In-app Uninstall is the only
  reset path (`systemextensionsctl uninstall` is SIP-blocked).
- AI Studio gaps: no visual layout editor (resize/reposition elements),
  no cross-deck card move/duplicate; legacy .ppt needs conversion to
  .pptx; PDF Lab/16-bit images are skipped (rare).
- The program monitor and OBS windows display aspect-fill
  (`.resizeAspectFill`): they crop the frame edges when their aspect
  differs from 16:9, while the virtual-camera feed and MP4 carry the
  full frame. Display only — the feed itself is intact.
- Motion-gesture triggers deliberately NOT implemented (signing is
  motion; still-holds only) — parked by user decision.
- Split-view presentation layout (picture tile + text band together)
  was parked in `docs/PENDING-FEATURES.md`, then IMPLEMENTED as the
  Split Text + Picture position in Build 83 (UNMERGED branch
  `live-generation`, ST-18 unverified) — judge §6's parked note as
  superseded on that branch only.
- Mouse brush (Build 74) parked in `docs/PENDING-FEATURES.md` as a
  future feature: implemented and unit-tested but never verified
  on-site (no crosshair; cause undetermined). The code is inert in
  the tree — judge it as dead-until-reactivated, not as working.
- Phase 2 leftovers (Top preset, appearance) skipped as low value.

## 7. Judging ask (to the reviewing model)

Act as an expert reviewer: senior Swift/macOS engineer + accessibility
consultant + privacy reviewer + AI-safety reviewer. Assume the claims
above are UNVERIFIED until you check them against the code (and tests
where behavior is covered). Be adversarial but fair: verify first, then
judge.

Evaluate and score 1–10 each, with evidence (file + line or test name):

1. **Correctness** — do the gesture pipeline, state machines, paint/
   brush lifecycles, compositor math, and virtual-camera IPC do what is
   claimed? Hunt for real bugs (off-by-ones, races, lock ordering,
  MainActor/Sendable holes, leaked state across cards/modes).
2. **Architecture** — is the separation (capture/analysis/composition/
   output, protocol seams, DI) clean and honestly testable? Any layering
   violations or hidden coupling?
3. **Gesture safety** — for a signing presenter, can normal signing
   plausibly fire commands? Audit stillness radii, gap tolerance,
   cooldown/debounce, the listening latch, and every suppression rule
   (paint/zoom/brush/clutch). Name the weakest link.
4. **Privacy** — camera-only local processing as claimed? Any network,
   analytics, or undeclared persistence? Is the MP4 path truly
   user-initiated and local-only?
5. **Accessibility** — large text/contrast/VoiceOver/status visibility
   as claimed? Gaps for low-vision or VoiceOver-only users?
6. **Tests** — does the suite prove what matters (list the 3 strongest
   and 3 weakest areas)? What high-risk behavior has no coverage and no
   honest manual substitute?
7. **Virtual camera robustness** — extension lifecycle, discovery,
   failure modes (denied/unavailable/disconnected camera, missing sink,
   queue-full, client hold-open). What breaks first under stress?
8. **Maintainability** — would a new contributor understand and safely
   extend this? Dead code, misleading comments, magic numbers?
9. **AI generation safety** — is the cloud path honestly gated (approval
   before every send, key handling, no webcam frames leaving, no key in
   logs/tests)? Are the accuracy rules (no invented facts/quotes,
   verse precision, diagram-over-pixels, faithful verbatim splits)
   actually enforced in prompts and code? Cost/abuse controls (caps,
   cancellation, no-art path)? What fails if the model misbehaves
   (garbage JSON, invented kinds, wrong language, non-empty faithful
   prompts)? Is the hand-rolled PPTX/zip parser robust (malformed
   input, zip bombs, crashes)?

Then deliver:

- A. **Verdict**: ship / ship-with-fixes / not-yet, in one sentence.
- B. **Top 5 defects or risks**, ranked, each with: severity, exact
  location, why it matters, and a concrete fix sketch.
- C. **Top 3 false or overstated claims** in sections 2–6 (quote the
  claim, show the contradicting code).
- D. **Top 3 genuinely strong decisions** worth keeping.
- E. Anything in the open-items list you disagree with (e.g. should
  motion triggers really stay parked?).

Rules: no credit for claims you didn't verify in code; distinguish
"checked and correct" from "plausible but untested" from "wrong". Keep
the whole review under ~1500 words plus the defect details.
