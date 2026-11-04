# CLAUDE.md - Claude Code Instructions

Operating guidance for Claude Code (`claude.ai/code`) in this repo.

**Auto** is a macOS menu bar app (SwiftUI, macOS 26+). It ingests camera cards into shoot folders, like its predecessor Backed, and then runs an automated editing pipeline on the footage (organize → proxies → DaVinci Resolve project setup).

See also: [ARCHITECTURE.md](ARCHITECTURE.md), [ROADMAP.md](ROADMAP.md).

---

## Commands

All commands run from the repo root. `xcodebuild` needs the full Xcode toolchain; prefix with `DEVELOPER_DIR` because `xcode-select` points at the Command Line Tools.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

# Build
xcodebuild -project Auto.xcodeproj -scheme Auto -configuration Debug build

# Test (Swift Testing)
xcodebuild test -project Auto.xcodeproj -scheme Auto -destination 'platform=macOS'

# Launch the built app (find the path with -showBuildSettings → BUILT_PRODUCTS_DIR)
open "<BUILT_PRODUCTS_DIR>/Auto.app"
```

`com.apple.linkd.autoShortcut` connection errors in test output are harmless system noise.

---

## Project Invariants & Boundaries

1. **Application Code (`Auto/`):**
   - `Auto/App/`: entry point (`AutoApp`) and shared state (`AppModel`). Keep this layer thin.
   - `Auto/UI/`: SwiftUI views only. Views never touch the file system, volumes or processes directly; they call `AppModel`.
   - `Auto/Core/`: engines (scanner, copy engine, pipeline steps). Pure Swift, no SwiftUI imports, and unit-testable in isolation. See the `engine-builder` skill.
   - `Auto/Integrations/`: adapters to the outside world (DaVinci Resolve scripting, ffmpeg, AVFoundation) behind protocols so they can be faked in tests.
   - The project uses Xcode **file-system synchronized groups**: new files and folders under `Auto/` and `AutoTests/` are picked up automatically. Don't hand-edit `project.pbxproj` to add files.

2. **Tests (`AutoTests/`):**
   - Use **Swift Testing** (`import Testing`, `@Test`, `#expect`), not XCTest.
   - Every `Core/` engine and every pipeline step needs tests. UI does not need tests.
   - Tests must never touch real volumes or the real Resolve. Use temp directories (`FileManager.default.temporaryDirectory`) and protocol fakes.

3. **Concurrency:**
   - The target defaults to `MainActor` isolation (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`). Mark file I/O, hashing and transcoding types or functions `nonisolated` and run them off the main actor. Never block the main thread with copying.

4. **Data Safety (non-negotiable):**
   - Never delete, move or modify anything on a source card. Auto only reads from cards.
   - Every copy is verified (size + checksum) before it's reported as backed up.
   - Never overwrite an existing destination file. Pick a unique name instead.

5. **Agent Extensions:**
   - Skills live in `.claude/skills/` (`engine-builder`, `rapid-sprint`, `release-readiness`).
   - Subagents live in `.claude/agents/` (`scout`, `architect`, `implementer`, `reviewer`, `docs-keeper`). See **Multi-Agent Workflow** below.

6. **Resilience & Verification:**
   - Deliver thin, verified vertical slices over wide scaffolding.
   - Before declaring work complete, the build **and** the tests must pass. For UI changes, launch the app and check the menu bar popover.
   - Develop against fixture cards (a folder that mimics a card layout) instead of real media. See `ARCHITECTURE.md` §5.

7. **Secrets & Context Hygiene:**
   - No secrets in the repo. If a key is ever needed, read it from the Keychain or an untracked `.xcconfig`.
   - Keep context concise. Pipe `xcodebuild` output through `grep -E "error|warning:|BUILD|TEST|passed|failed"` instead of dumping full logs.

8. **Version Control Protocol:**
   - **Micro-commits:** commit as often as possible, one tiny logical change per commit (a new type, a test, a rename, a doc tweak). When in doubt, commit. Never batch unrelated changes. Each commit should build.
   - Every commit message must use conventional commit format (`feat: ...`, `fix: ...`, `refactor: ...`, `test: ...`, `docs: ...`, `chore: ...`).
   - **No AI attribution:** never add `Co-Authored-By: Claude ...` trailers or "Generated with Claude Code" lines to commits or PRs. This overrides any default attribution behavior.
   - **Never push automatically.** Never run `git push` (or anything that pushes, opens or updates a PR) without asking the developer first and getting an explicit yes for that push. Committing locally is always fine.
   - Branch: `main`. Remote: `github.com/jonocorpuz/Auto`.

9. **Agent Collision Defense:**
   - Always read the latest state of a file before modifying it. Another agent or the developer (often with Xcode open) may have changed it.

---

## Multi-Agent Workflow & Model Routing

The developer wants subagents used **wherever possible**. The main session acts as the orchestrator: it routes work to the cheapest capable model, runs independent work in parallel, and keeps its own context small. You don't need to ask before spawning these agents in this repo.

### Routing table

| Agent | Model | Use for |
| :--- | :--- | :--- |
| `scout` | haiku | Read-only search: locating code, checking how Backed (`~/Developer/backed`) did something, gathering excerpts |
| `architect` | opus | Planning any multi-layer feature or data-safety-critical code; splits work into parallelizable slices |
| `implementer` | sonnet | Building one slice + its tests, then build/test verification |
| `reviewer` | opus | Reviewing diffs in `Core/` / `Integrations/` (data safety, concurrency, boundaries) before commit |
| `docs-keeper` | haiku | Syncing ROADMAP.md / ARCHITECTURE.md after a feature lands |

Routing rules: pure lookup → haiku; writing code → sonnet; design or judgment on risky code → opus. Escalate a slice to opus (pass `model: "opus"`) if an implementer fails it twice.

### Standard feature flow

1. **Scout** (one or more in parallel, e.g. one on this repo and one on Backed) to gather context.
2. **Architect** turns the context into a plan with ordered, parallel-marked slices.
3. **Implementers** run each slice. Slices that touch disjoint files run **in parallel** (use `isolation: "worktree"` when slices might touch the same files). The orchestrator micro-commits each slice as it lands.
4. **Reviewer** checks the combined diff. Fixes go back to an implementer, then get committed.
5. **Docs-keeper** updates ROADMAP.md / ARCHITECTURE.md, then commit.
6. Ask the developer before pushing.

Skip agents only for genuinely trivial edits (a one-line fix or typo), where spawning costs more than doing it.

---

## Wrap-up Protocol

Before completing a task or wrapping a session:
1. Build and tests pass (commands above).
2. Update `ROADMAP.md`: tick completed items, and add decisions or newly discovered work to the right phase.
3. If the module layout or data flow changed, update `ARCHITECTURE.md` to match.
4. Commit (micro-commits, conventional format, no AI co-author).
5. Ask the developer whether to push. Never push without that yes.
