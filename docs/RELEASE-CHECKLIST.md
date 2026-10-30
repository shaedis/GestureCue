# Release Checklist (branch `visual-pedagogy`)

## Automated (agent, every build)

- [ ] `xcodebuild -scheme GestureCue -destination 'platform=macOS' test` — all green (baseline: 282)
- [ ] Zero build warnings (`warning:` empty apart from AppIntents metadata noise)
- [ ] `make app` + `codesign --verify --deep --strict build/GestureCue.app`
- [ ] Window title shows the new build number

## Manual (human + camera + Zoom)

- [ ] `docs/USER-VERIFICATION-GATE.md` — every ST + VC box ticked with evidence
- [ ] `docs/fix-issues.md` — every item re-verified on the staged build
- [ ] Demo dry-run from `docs/DEMO-SCRIPT.md` (3 minutes, in Zoom)

## Before commit / push / tag (agent + human)

- [ ] `git status` reviewed: only intended files; `.env` untracked + ignored
- [ ] No API keys, private lessons, or secrets in the diff (`git diff` scanned)
- [ ] Local-only docs (`prompts/`, `instruction.md`, `visual_Pedagocical_generator.md`,
      `fix-issues.md`, `next_step_1.md`, `new-features.md`) stay uncommitted
- [ ] PROGRESS.md + AGENTS.md resume notes current
- [ ] Commit + push + tag only on explicit user go
