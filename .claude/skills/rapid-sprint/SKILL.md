---
name: rapid-sprint
description: >-
  Framework for sprint velocity, scope management and delivering verified
  vertical slices in Auto, paced against ROADMAP.md. Use when planning what to
  build next, triaging scope, or breaking a phase into slices.
---

# Rapid Sprint Velocity & Scope Management Skill

Use this skill when pacing work, triaging feature scope and keeping momentum toward a working end-to-end flow: **card in → backed up → pipeline ran**.

---

## 1. Phases

Phases and their checklists live in `ROADMAP.md`. Work the current phase top-down; don't start Phase 3 polish while Phase 2 ingest is unverified.

| Phase | Focus | Done when |
| :--- | :--- | :--- |
| 1. Foundation | Shell, settings, tests | App launches in the menu bar; tests run |
| 2. Ingest parity | Scanner, verified copy, folders | A fixture card ingests end-to-end with verified copies |
| 3. Editing pipeline | Organize, proxies, Resolve | A fixture shoot gets proxies + a Resolve project |
| 4. Polish & release | Notifications, signing | `release-readiness` checklist passes |

---

## 2. Scope Slashing & Prioritization

When a feature risks stalling:
1. **The core flow first.** One path (one camera type, one destination) working with real verification beats three half-built paths.
2. **Pragmatic deferrals.** Push multi-destination, history and launch-at-login to Phase 4 or the Backlog.
3. **Fake fragile integrations.** If Resolve scripting is flaky, build against the `ResolveClient` fake and ship the step as "skipped when unavailable".
4. **Record it.** Move deferred items to `ROADMAP.md` → Backlog, and log the reason in Key Decisions.

---

## 3. Atomic Slice Loop

For every slice:
1. **Spec:** add or confirm a 1-line checklist item in `ROADMAP.md` with clear done-criteria.
2. **Build:** engine in `Core/` (see `engine-builder`), glue in `AppModel`, view in `UI/`.
3. **Verify:** build + tests pass; for UI, launch the app and click through the popover.
4. **Record:** move the item from `ROADMAP.md` to `docs/ROADMAP-done.md` and commit (`feat: ...`).
