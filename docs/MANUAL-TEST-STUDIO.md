# Manual test — AI Visual Education Studio (ST-01..12)

Branch `visual-pedagogy`, staged app `build/GestureCue.app` (window title
shows the build; use Build 62+). Needs a Meta Model API key
([dev.meta.ai](https://dev.meta.ai)) and, for ST-10..12, a camera plus
Zoom or QuickTime. Automated coverage (client parsing, credential stores,
import, composer, diagrams, round-trip) is in `GestureCueTests/`; these
steps verify what only hardware, the live API, and eyes can confirm.
Never mark a step passed without doing it.

## Key + approval

- ST-01 Save the key in the Studio, quit, relaunch: key still present
  (Keychain round-trip), key field empty (never echoed).
- ST-02 With no approval ticked, Generate stays disabled; ticking approval
  then importing new source resets the tick (per-lesson approval).
  Editing the source text after ticking resets it too.

## Import

- ST-03 Paste a history text (~1 page): title/note look right, Generate
  enables after approval.
- ST-04 Import a PDF and a PowerPoint file: text extracts readably
  (spot-check against the file); oversized sources show the truncation note.
  The Studio shows the faithful-mode caption; generating from either
  yields verbatim splits (no rewritten text, no new illustrations).

## Generate + review (MVP-A history, MVP-B fractions)

- ST-05 Generate 5 history cards: all drafts arrive with titles, bodies ≤
  ~4 lines, labels, and illustrations; facts/dates match the source
  (check 2+ dates against the text).
- ST-06 Generate 5 fractions cards: every math statement correct
  (spot-check 1/2 = 2/4 and 1/2 + 1/4 = 3/4); exact cards use diagrams,
  not pixels, for numbers.
- ST-07 Edit one card's title + one illustration prompt: only the edited
  card shows the dirty marker; Regenerate Changed refreshes just it;
  Refresh Text updates wording with no new API art.
- ST-08 Save to a collection, then Edit Existing Deck: artwork, prompts,
  and labels come back; an untouched re-import shows no dirty markers.

## Present on video

- ST-09 Show a saved lesson on camera: every card readable in the Program
  Output monitor, nothing clipped, picture + text side by side, signer
  area (top ~70%) clear.
- ST-10 Select **GestureCue Camera** in Zoom/QuickTime: the lesson cards
  appear in the call; Next/Previous gestures advance while streaming.
- ST-11 Two-finger brush highlights card text live in the call and fades;
  Expand (E / three fingers) fills the frame for small participant tiles.
- ST-12 Cancel mid-generation (close or Cancel): progress stops, partial
  drafts stay editable, and no stuck spinner or error sheet remains.

Record results (pass/fail + build + date) in `PROGRESS.md`.
