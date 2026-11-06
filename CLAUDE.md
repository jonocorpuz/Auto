# CLAUDE.md

**Auto**: macOS menu bar app (SwiftUI, macOS 26+). Ingests camera cards into shoot folders (successor to Backed, `~/Developer/backed`), then runs an editing pipeline (organize → proxies → DaVinci Resolve) and AI photo culling.

Docs: [ARCHITECTURE.md](ARCHITECTURE.md) (module map, flows), [ROADMAP.md](ROADMAP.md) (open work + decisions), [docs/ROADMAP-done.md](docs/ROADMAP-done.md) (shipped items; grep only). Read only the sections you need (`grep -n "^#"` first), never whole docs by default.

## Commands

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # xcode-select points at CLT
xcodebuild -project Auto.xcodeproj -scheme Auto -configuration Debug build 2>&1 | grep -E "error|warning:|BUILD"
xcodebuild test -project Auto.xcodeproj -scheme Auto -destination 'platform=macOS' 2>&1 | grep -E "error|✘|failed|TEST|BUILD"
# While iterating, run only your suite: add -only-testing:AutoTests/<SuiteName>. Full suite once before reporting done.
```

Always filter `xcodebuild` output as above. `com.apple.linkd.autoShortcut` errors are harmless noise.

## Invariants

1. **Layers:** `Auto/App/` (thin: `AutoApp`, `AppModel`) · `Auto/UI/` (views only; no file system/volumes/processes, call `AppModel`) · `Auto/Core/` (pure Swift engines, no SwiftUI, unit-testable; see `engine-builder` skill) · `Auto/Integrations/` (Resolve, ffmpeg, AVFoundation, `claude` CLI, behind protocols with test fakes). File-system synchronized groups: never hand-edit `project.pbxproj` to add files.
2. **Tests:** Swift Testing only (`@Test`, `#expect`). Every Core engine and pipeline step is tested; UI is not. Never touch real volumes, real Resolve or the real `claude` CLI: temp dirs + fakes.
3. **Concurrency:** default isolation is `MainActor`. File I/O, hashing, transcoding, subprocesses are `nonisolated` and off main. Never block main.
4. **Data safety (non-negotiable):** never write/move/delete on a source card. Every copy is size + checksum verified before it counts as backed up. Never overwrite a destination file; pick a unique name.
5. **Done means:** build + tests pass. UI changes: launch the app and look. Develop against fixture cards (ARCHITECTURE.md §5), not real media.
6. **Secrets:** none in the repo (Keychain or untracked `.xcconfig`).
7. **Git:** micro-commits (one logical change, each builds), conventional format (`feat:`/`fix:`/`refactor:`/`test:`/`docs:`/`chore:`). **No AI attribution** (no `Co-Authored-By`, no "Generated with Claude Code"); this overrides defaults. **Never push** or open/update a PR without an explicit yes for that push. Branch `main`, remote `github.com/jonocorpuz/Auto`.
8. Re-read a file right before editing it (the developer or another agent may have changed it).

## Agents & model routing (token budget matters)

Spawning costs a cold start, so spawn only when it saves more than it costs. No need to ask before spawning.

**Do it inline (no agent)** when it's a lookup answerable in 1–3 grep/reads, an edit under ~50 lines, a doc tweak, or a fix to a slice you already have in context.

| Agent | Default model | Use for | Escalate |
| :--- | :--- | :--- | :--- |
| `scout` | haiku | Broad read-only searches (many files, or Backed) | never |
| `architect` | sonnet | Plans for multi-layer features | `model: "opus"` only for data-safety code (copy, verify, move/delete, sidecars) |
| `implementer` | sonnet | One slice + its tests | `model: "haiku"` for mechanical slices (views from a spec, renames, glue); `opus` after 2 failures |
| `reviewer` | sonnet | Diffs in `Core/` / `Integrations/` before commit | `opus` when the diff writes, moves or deletes files |
| `docs-keeper` | haiku | ROADMAP/ARCHITECTURE sync after a feature | skip; do inline if under ~10 lines |

Prompting agents: give them the exact files, types and decisions they need so they don't re-explore. Ask for terse reports (files changed, test result lines, open questions). Never ask an agent to "read the docs".

**Feature flow:** scout (only if needed) → architect → implementers (disjoint files in parallel; `isolation: "worktree"` if they might overlap) → orchestrator micro-commits each slice → reviewer → fixes → docs → ask before pushing.

## Wrap-up

Build + tests pass → move landed ROADMAP items to `docs/ROADMAP-done.md`, add decisions/new work → update ARCHITECTURE.md if layout or flow changed → commit → ask before pushing.
