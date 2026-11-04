---
name: engine-builder
description: >-
  Standard procedure for building an isolated, testable Core engine or pipeline
  step in Auto/Core (scanner, copy engine, organize/proxy/Resolve steps). Use when
  adding or changing processing logic that touches files, media or external tools.
---

# Engine Builder Skill

Use this skill when implementing self-contained processing logic in `Auto/Core/` or an adapter in `Auto/Integrations/`.

---

## 1. What is an Engine?

An **engine** is a single-responsibility Swift type that does one job reliably (scan a card, copy and verify files, generate proxies) with **no SwiftUI and no knowledge of `AppModel`**. Keeping logic in engines stops `AppModel` and the views from turning into a tangled, untestable blob, which is what happened to Backed's `AppModel`.

A **pipeline step** is an engine that conforms to `PipelineStep` and runs on an ingested shoot.

### Anatomy

```text
Auto/Core/<Area>/
├── <Engine>.swift          # the engine: plain types in, plain types out
└── <Engine>Models.swift    # (optional) input/output value types

AutoTests/<Area>/
└── <Engine>Tests.swift     # Swift Testing suite using temp dirs + fakes
```

---

## 2. Steps to Build an Engine

1. **Define the contract first.** Write the input and output as `Sendable` value types (structs/enums). Errors are a nested `enum: LocalizedError` with user-readable messages.
2. **Isolation.** The target defaults to `MainActor`. Mark the engine `nonisolated` (or make it an `actor`) if it does I/O, hashing or transcoding, and expose `async` APIs. Report progress through a callback or `AsyncStream`; never touch the UI.
3. **External tools go through a protocol.** For Resolve, ffmpeg or anything that spawns a `Process`, define a protocol in `Integrations/`, a real implementation, and a fake in `AutoTests/`.
4. **Data safety.** Sources are read-only. Write to a temp name and rename atomically. Never overwrite. See CLAUDE.md §4.
5. **Write tests alongside** (`AutoTests/<Area>/`):
   - Build fixtures in `FileManager.default.temporaryDirectory` with a unique subfolder, and clean up in `deinit` or at the end of the test.
   - Cover the happy path, one failure path (e.g. mismatch or missing file), and cancellation if supported.
   - Use `@Test(arguments:)` for camera/layout variants.
   - Tests should run in < 2 seconds; use tiny files.
6. **Wire into `AppModel`.** `AppModel` owns the engine instance, calls it, and maps results into UI state. Keep that glue thin.
7. **Verify:** build + `xcodebuild test` pass. Then update ARCHITECTURE.md (module map) and ROADMAP.md (tick the item).

---

## 3. Pipeline Step Contract (Phase 3)

```swift
protocol PipelineStep: Sendable {
    var id: String { get }            // stable, e.g. "proxies"
    var title: String { get }         // shown in UI
    func run(on shoot: Shoot, progress: @Sendable (Double) -> Void) async throws -> StepResult
}
```

- Steps must be **idempotent**: running twice on the same shoot doesn't duplicate output.
- A step that can't run (e.g. Resolve not open) returns `.skipped(reason:)`, not a thrown error.
