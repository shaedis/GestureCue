# GestureCue Accessibility — Native macOS Application (Milestone 1 Spec)

You are a senior macOS engineer specializing in SwiftUI, AVFoundation, Apple Vision, real-time computer vision, accessibility, and agentic software development.

Your task is to BUILD, not merely design, the first working version of **GestureCue Accessibility**, a native macOS application for controlling accessible visual presentation cards using hand gestures detected by the Mac's webcam.

## 1. Follow AGENTS.md first

Before making any changes:

- Inspect the repository and its current structure.
- Read the existing `AGENTS.md` and any applicable nested agent instruction files.
- Follow all existing project conventions, architecture rules, testing requirements, and security instructions.
- If `AGENTS.md` does not exist, create one containing concise project-specific architecture, coding, testing, privacy, and accessibility guidelines.
- Never overwrite an existing `AGENTS.md`.
- Keep the implementation modular, maintainable, and testable.

Briefly describe the implementation plan, then proceed with implementation without requiring approval for every ordinary step.

## 2. Project purpose

GestureCue Accessibility is designed primarily for Deaf and hard-of-hearing audiences.

During presentations, audiences may need to divide their attention between a sign language interpreter, captions, slides, and the speaker.

GestureCue allows a presenter to display important visual messages using simple hand gestures, without using a keyboard or mouse.

The application must eventually support AI-assisted generation of short, accessible messages, but this first milestone focuses on reliable real-time hand gesture recognition and visual feedback.

## 3. Technology requirements

Build a real, native Mac application using:

- Swift and SwiftUI for the user interface.
- AVFoundation for live webcam capture.
- Apple Vision for hand landmark detection.
- `VNDetectHumanHandPoseRequest` for hand tracking, or its appropriate supported equivalent if required by the installed SDK.
- AppKit only when needed for native macOS window management.
- An appropriate macOS deployment target supported by the installed Xcode version.

Avoid Electron, React, Python camera services, cloud vision services, and unnecessary third-party dependencies.

All camera processing must run locally on the Mac.

## 4. Main interface

Create a modern and accessible macOS application with:

**Camera panel**
- Live webcam preview.
- Start/Stop Camera controls.
- Camera permission status.
- Camera selection when multiple cameras are available.
- Optional hand landmark visualization over the video.
- Current recognized gesture and confidence/status feedback.

**Gesture control panel**
- Display the recognized hand gesture.
- Display the corresponding action.
- Configure which of the three supported gestures triggers each action.
- Show whether the gesture is stable enough to trigger an action.
- Provide visual feedback when an action is executed.

**Presentation card panel**
- Show a large, readable visual information card.
- Provide at least three example cards.
- Show, hide, and advance cards using gestures.
- Provide equivalent mouse and keyboard controls.

Design the interface with accessibility as a primary requirement: large text, clear contrast, visible status indicators, VoiceOver-friendly controls, and no dependence on sound.

## 5. Implement three hand gestures

Implement an initial gesture recognition system supporting:

| Gesture | Default action |
|---|---|
| Open palm | Show current card |
| Thumbs-up | Hide card |
| Thumb pointing right (your right) | Next card |
| Thumb pointing left (your left) | Previous card |
| Closed fist | Unassigned by default (too common in signing) |
| Index finger pointing up | Unassigned by default (occurs in signing) |
| Two fingers up | Unassigned by default (occurs in signing) |

The gesture-to-action mapping must be configurable.

Use hand landmarks and geometric relationships to classify these gestures.

Implement:
- Landmark confidence filtering.
- Temporal smoothing across frames.
- Gesture stability requirements.
- Debouncing to prevent repeated accidental activations.
- An action cooldown.
- A neutral or unknown gesture state.
- Graceful handling when no hand is detected.

Avoid rigid pixel-coordinate thresholds that fail with different camera resolutions or hand positions.

Gesture detection must run off the main UI thread and must not block the interface.

## 6. Camera and privacy

- Request explicit camera permission.
- Configure `NSCameraUsageDescription`.
- Handle denied permissions with clear instructions.
- Handle disconnected or unavailable cameras.
- Release camera resources when capture stops.
- Never record, store, or upload camera video.
- Do not request microphone access.

## 7. Architecture

Use clear separation of responsibilities, such as:

- CameraManager
- HandPoseDetector
- GestureClassifier
- GestureStateMachine
- GestureActionRouter
- PresentationCardStore
- AppViewModel
- SwiftUI Views

Choose the architecture that best fits the actual project and explain any deviations.

Use protocols and dependency injection where useful so gesture classification and application behavior can be tested without a physical camera.

## 8. Testing and quality

Write unit tests for:
- Individual gesture classification.
- Confidence thresholds.
- Gesture stabilization.
- Cooldown and debouncing.
- Gesture-to-action mapping.
- Presentation card state transitions.

Build the application using the available Xcode tools.

Fix compiler errors and run the available automated tests.

If hardware testing is unavailable, clearly distinguish automated verification from unverified physical webcam functionality.

Do not use fake camera detections to claim real webcam recognition works.

## 9. Scope for this milestone

Focus on the following working user journey:

1. User launches GestureCue.
2. User grants camera permission.
3. Live camera preview starts.
4. Hand landmarks are detected.
5. Gesture is recognized.
6. The recognized gesture triggers the configured action.
7. The visual presentation card updates immediately.
8. User can stop the camera safely.

Use manually created sample cards for now.

Do NOT implement Meta AI integration, speech recognition, cloud APIs, or advanced presentation imports in this milestone.

Keep the architecture ready for future Meta Muse Spark integration.

## 10. Deliverables

Produce:

- A complete native macOS application project.
- Working source code.
- A usable SwiftUI interface.
- Real-time webcam hand tracking.
- Three configurable gesture actions.
- Sample presentation cards.
- Unit tests.
- A README explaining setup, build, permissions, limitations, and how to run the app.
- Updated project instructions where needed.

At completion, report:

1. What was implemented.
2. The main architecture decisions.
3. Build and test results.
4. What was not verified.
5. Known limitations.
6. The recommended next development milestone.

**Success criterion:** I can open the macOS application, enable my webcam, show my hand to the camera, and control visible presentation cards using the three supported gestures.

## Amendment: virtual-camera-ready pipeline

The camera pipeline must be separated into `VideoCaptureService` (capture), `HandGestureDetector` (local analysis), `VideoCompositor` (camera + card/graphics compositing), and `VideoOutputService` (protocol-isolated destinations), sharing one capture pipeline and targeting 1280×720 @ 30 FPS. A future `VirtualCameraService` (CoreMediaIO camera extension) will feed the processed video to Zoom/Teams; milestone 1 ships the in-app program monitor only and must not require a rewrite to add it. Binding architectural rules live in `AGENTS.md` ("Video pipeline" section).

## Amendment: Back gesture + far-hand tolerance

A fourth gesture was added from user testing: **two fingers up → Previous Card** (with Previous button + ← key). The state machine now tolerates up to 2 non-matching frames without losing the stability candidate (absorbing jitter on small/distant hands) and gates frames at 0.35 confidence instead of 0.45; release/re-arm requires a sustained unknown run. The UI shows a hand detected/not-detected indicator to separate Vision misses from classification misses during manual testing.

In-video card position options (Bottom/Left/Right, persisted) were added from user testing as the first slice of Phase 2; drag/resize and composition modes remain Phase 2 scope.

An expandable program-output window (second output branch sharing the compositor) was added from user testing; the clean OBS window stays Phase 4 scope.

Automatic title highlighting was replaced per user feedback with finger painting (Paint Mode + pinch-drag strokes, Yellow/Red, per-card Undo/Redo/Clear): two-finger pinch paints, single index advances. Cards support optional pictures below the texts (open-panel attach). Gestures are hold-to-fire: the same pose held approximately still ~0.5 s; hand motion restarts the hold so signing never triggers actions.
