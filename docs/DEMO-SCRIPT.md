# GestureCue — 3-minute competition demo (Build 51)

Setup: staged app in `/Applications`, camera on, Meta API key saved,
Zoom open with **GestureCue Camera** selected. Have a history text and a
fractions text ready to paste.

## 0:00–0:30 The problem

Signing on a video call while showing slides forces Deaf viewers to
split attention between interpreter, captions, and screen — cues get
missed. GestureCue puts big visual cards *inside* the presenter's own
camera feed, driven by hand gestures, so interpreter and content share
one frame.

## 0:30–1:10 Import → Meta AI generates the lesson

Paste the history text into the AI Studio, tick approval, Generate.
Muse Spark plans 5 visual cards; Muse Image illustrates them; exact
content (dates, fractions) renders as local deterministic diagrams —
never trusted to pixels. Show the drafts: title, short body, labels,
artwork.

## 1:10–1:40 Review → save

Retitle one card, tweak one illustration prompt, Regenerate Changed
(only that card refreshes), Refresh Text (free local re-composition),
save to the History collection.

## 1:40–2:30 Live in Zoom

Switch to Zoom: the lesson cards are in the call via GestureCue Camera.
Hold palm 2 s to latch listening (green dot), hold gestures to
show / next / previous, two-finger brush to highlight text (fades),
Expand for small tiles. Fist 2 s to stop — signing stays ignored.

## 2:30–3:00 How it works

One local pipeline: capture fans out to Vision gesture recognition and
to the compositor (camera + cards + paint), which feeds the in-app
monitor, the native CoreMediaIO virtual camera, and MP4 recording.
Only approved source text ever leaves the Mac, to the Meta Model API;
frames never do. 244 automated tests; gestures verified on camera.
