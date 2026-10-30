# GestureCue — Simplify AI Studio with Optional AI Instructions

Read AGENTS.md and inspect the existing AI Studio, Meta Model API integration, source import, and generation workflow.

## Objective

Keep the existing Source Material workflow and add ONE optional field called:

**AI Instructions (Optional)**

Do NOT implement two separate generation modes or introduce a new Prompt Only mode.

## Requirements

1. Preserve the existing Source Material field, including:
   - Pasted text
   - PDF imports
   - PowerPoint imports
   - Other currently supported documents

2. Add a multiline "AI Instructions (Optional)" field directly below Source Material.

3. If AI Instructions is EMPTY:
   - Run the existing Meta AI generation workflow unchanged.
   - Use the application's current default educational instructions, visual settings, and generation rules.
   - Preserve backward compatibility.

4. If AI Instructions is PROVIDED:
   - Include the user's instructions in the Muse Spark request.
   - Apply them when transforming the source into educational cards.
   - Allow instructions for illustration style, educational level, visual explanations, timelines, diagrams, labels, and content emphasis.
   - Generate relevant images through the existing Muse Image integration.

5. Keep Source Material and AI Instructions separate in the API request.

6. Follow custom instructions wherever possible, but never allow them to override:
   - Source accuracy and factual integrity.
   - Explicit application settings such as card count or language.
   - Privacy and user approval requirements.
   - Existing safety and content validation rules.

7. Preserve the current distinction between Visual Educational Mode and Faithful Presentation Mode, if implemented. In Faithful Mode, optional instructions must not silently rewrite the original content.

8. Save AI Instructions with the presentation so users can edit and regenerate it later.

9. When reopening a saved AI presentation, restore its custom instructions.

10. Ensure changing the instructions does not silently discard saved cards, illustrations, or annotations.

11. Do not change the existing camera, gesture recognition, catalog, virtual camera, or MP4 recording functionality.

## Tests

Verify:

- Empty AI Instructions → unchanged default behavior.
- Custom AI Instructions → instructions are included in the Meta request and reflected in the generated result.
- Works with pasted text.
- Works with PDF.
- Works with PowerPoint.
- Saves and restores custom instructions.
- Existing saved presentations continue working.
- Invalid or conflicting instructions are handled safely.

Run the complete XCTest suite and build the macOS application.

## Acceptance Test

Source Material:
A short historical text about Sputnik 1, Yuri Gagarin, Apollo 11, and the International Space Station.

AI Instructions:
"Create four illustrated educational cards for Deaf children aged 10–15. Use colorful illustrations, short readable text, historical dates, and visual timelines."

Expected:
- Four illustrated cards.
- Correct historical dates.
- Short readable explanations.
- Relevant illustrations.
- Editable content.
- Successful Catalog save.
- Correct display inside GestureCue's composited video.

Then repeat with an EMPTY AI Instructions field to verify the existing default generation still works.

Implement this as one focused change.

Do not add unrelated features or redesign the AI Studio.

Update PROGRESS.md and report build and test results.