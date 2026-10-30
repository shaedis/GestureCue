# GestureCue Build 57 — Final MVP Improvements and Release Gate

Read AGENTS.md, PROGRESS.md, the current source code, and all applicable test plans.

Do not add unrelated features or rewrite existing working components.

## Task 1 — Educational Generation Modes

Audit the current PDF, PowerPoint and text import workflows.

Implement an explicit choice:

A. Visual Educational Mode
- Transform imported material into accessible illustrated educational lessons.
- Support historical timelines, mathematical diagrams, step-by-step illustrations and explanatory cards.
- Use Muse Spark and Muse Image as appropriate.
- Preserve source fidelity, show references, and require human review.
- Reuse the existing catalog and video compositor.

B. Faithful Presentation Mode
- Preserve original text and ordering.
- Do not generate extra artwork.
- Verify exact source text against extracted content.
- Never claim verbatim fidelity based solely on low-temperature AI output.

Both modes must support PDF, PowerPoint and text-based input wherever extraction is supported.

## Task 2 — Meta API Reliability

Verify whether JSON Schema-constrained responses work with the configured Muse Spark model and API endpoint.

Use strict schema validation where supported.

Implement graceful handling for unsupported diagram types, malformed responses, invalid artwork, timeouts and rate limits.

Preserve existing user approval and Keychain protections.

## Task 3 — Import Security

Audit the native PPTX/PPSX ZIP and XML reader.

Check:
- Malformed files.
- Archive entry-count limits.
- Maximum decompressed size.
- ZIP bombs.
- Unsafe paths.
- XML entity handling.
- Memory exhaustion.
- Graceful failure without application crashes.

Add focused regression tests for confirmed gaps.

## Task 4 — Real Application Verification

Complete the actual Build 57 Studio workflow:

1. Import an educational history PDF.
2. Generate illustrated cards.
3. Edit and approve cards.
4. Save and reopen the presentation.
5. Select it in GestureCue.
6. Show the cards inside the live video.
7. Highlight an illustration with finger gestures.
8. Verify output through the native virtual camera in Zoom.
9. Record an MP4 and verify playback.

Repeat with a mathematical fractions lesson.

Run ST-01 through ST-12 and VC-01 through VC-07.

Do not mark manual tests complete without real user verification.

## Task 5 — Release Preparation

Run all automated tests against the Build 57 baseline of 256 tests.

Audit Swift concurrency warnings and fix any confirmed risks.

Check Git status and prepare the visual-pedagogy branch for a clean public submission.

Verify no credentials, generated private materials, or development secrets are committed.

Document what was created during the hackathon.

Prepare a three-minute demo script and release checklist.

## Required Final Report

Provide:
- Verified features.
- Automated test results.
- Manual test results.
- Remaining critical defects.
- Exact source file and line references for confirmed issues.
- Real Meta API integration evidence.
- Release readiness verdict.

Prioritize only defects that affect the competition demonstration, security, data integrity or core accessibility.

Stop before adding optional functionality.

Begin the audit and implement the minimum necessary fixes.