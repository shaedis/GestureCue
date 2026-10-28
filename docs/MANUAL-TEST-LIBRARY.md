# Manual Test Checklist — Presentation Library & Import

App: `build/GestureCue.app` (Build 20+).
Scope: presentation catalog (create/select/rename/delete decks, author
cards) and file import (PDF native, PowerPoint via LibreOffice).

Fill in Result (`[x] Pass` / `[x] Fail`) and Notes as you go.

- Tester:
- Date:
- macOS / Mac model:

## Catalog (LIB-01…LIB-03)

- [ ] LIB-01 — Presentation picker lists "Sample Deck" and "Matteus 6".
  Manage… → New Deck
  → a new deck appears and is selected; rename it via the name field.
  Quit and relaunch: decks and names persist.
- [ ] LIB-02 — In the new deck: Add Card, edit title/message/detail,
  attach a picture. The card shows in the panel AND in the video;
  gestures navigate it. Persist across relaunch.
- [ ] LIB-03 — Switch decks via the picker: video follows the active
  deck. Delete a deck (the last one is protected). Never crashes on
  empty decks (Add Card to a 0-card deck works).

## Import (LIB-04…LIB-06)

- [ ] LIB-04 — Import a multi-page PDF: a deck named after the file
  appears with one card per page; slide images fill the card below the
  title and render readably in the video (expand fullscreen to check
  small text). Persists.
- [ ] LIB-05 — Import a .pptx with LibreOffice installed: same as LIB-04.
  Without LibreOffice: a clear error names the missing app (no hang).
- [ ] LIB-06 — Paint strokes stick to their cards across deck switches
  and relaunch (stable card identities).
- [ ] LIB-07 — Zoom: on a picture card, +/− buttons (or keys) scale the
  slide centered in its box (100%→400%, clipped to card); zoom out stops
  at 100%; per-card zoom survives card switches for the session.
  Pinch gesture (presentation mode only): hold index up with THUMB
  RAISED, then spread apart to zoom in / pinch together to zoom out.
  Index up with thumb tucked still fires card commands; the two never
  mix (zoom hand shows ZOOM in the diagnosis line).

## Sign-off

- [ ] Library + import accepted — Tester, date:
- [ ] Blockers (if any):
