---
name: release-readiness
description: >-
  Pre-release verification for Auto: clean build and tests, fixture-card
  end-to-end runs, data-safety checks, signing/notarization, and a short demo
  walkthrough. Use before tagging a release or demoing the app.
---

# Release Readiness & Verification Playbook

Use this skill to harden Auto, confirm error-free runs, and prepare a release or walkthrough.

---

## 1. Release Defense Checklist

- [ ] **Clean build:** `xcodebuild -scheme Auto -configuration Release build` succeeds with zero warnings from our code.
- [ ] **Tests green:** `xcodebuild test -scheme Auto -destination 'platform=macOS'` passes.
- [ ] **Clean first launch:** delete prefs (`defaults delete com.jonocorpuz.Auto`), launch, and check that the menu bar icon appears and Settings prompts for a work folder.
- [ ] **Fixture card end-to-end:** run with `-AutoFixtureCard <path>` and confirm detection → new shoot → copy → verify → pipeline steps all report success.
- [ ] **Data safety:**
  - [ ] Source fixture is byte-identical after the run (compare hashes before and after).
  - [ ] Re-running the same card copies nothing new and doesn't overwrite anything.
  - [ ] Cancelling mid-copy leaves no partial files under final names.
- [ ] **Resolve unavailable:** quit Resolve, run the pipeline, and confirm the Resolve step shows "skipped" and the ingest still succeeds.
- [ ] **Real card smoke test:** one real card from each supported camera.
- [ ] **Console clean:** no unexpected errors in Console.app filtered to `Auto` (ignore `linkd` noise).
- [ ] **Signed & notarized:** `codesign --verify --deep --strict Auto.app` and `spctl -a -vv Auto.app` pass.
- [ ] **Docs:** ROADMAP.md phase items moved to docs/ROADMAP-done.md; ARCHITECTURE.md matches the code; README run instructions still accurate.

---

## 2. Walkthrough Structure

1. **Problem (30s):** offloading cards and setting up edits is manual and error-prone.
2. **Core flow (90s):** insert a card → Auto pops up → pick client/shoot → verified copy with progress → proxies + Resolve project open automatically.
3. **Engineering (30s):** layer boundaries from ARCHITECTURE.md, verified copies, testable engines.
4. **Next (30s):** the next items from ROADMAP.md.

---

## 3. Live-Demo Resilience

- Keep a fixture card folder ready in case a real card or reader misbehaves.
- If Resolve hangs, the pipeline should skip that step gracefully. Show the backed-up shoot folder instead.
