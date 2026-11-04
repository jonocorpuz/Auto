# System Architecture & Technical Design

The architectural blueprint, module boundaries, data flows and design principles for **Auto**.

See also: [CLAUDE.md](CLAUDE.md), [ROADMAP.md](ROADMAP.md).

> **Status:** `App/`, `UI/` and `Core/` exist (Phase 2 ingest parity, in progress). `Integrations/` has the thumbnail adapter; Resolve and transcoding, and the Phase 3 pipeline, are still the target design (see ROADMAP.md). Keep this file in sync as modules land.

---

## 1. High-Level System Architecture

Auto is a single-process macOS menu bar app (`LSUIElement`, no Dock icon). It cleanly separates the SwiftUI interface, shared app state, pure processing engines, and adapters to external tools.

```mermaid
flowchart TD
    subgraph UILayer ["UI (Auto/UI)"]
        Main["MainView\nsidebar + content panel"]
        Sidebar["Sidebar\ntabs, New Shoot, account"]
        Media["MediaView\ncards, Shoots grid (ShootTile), drives"]
        CardRow["CardRow\nper-card phase, Add to Shoot, actions"]
        NewShoot["NewShootView\nsheet: create shoot"]
        AddFootage["AddFootageSheet\ncopy a card into a shoot"]
        Settings["SettingsView"]
    end

    subgraph AppLayer ["App (Auto/App)"]
        Delegate["AppDelegate\nNSStatusItem, main window"]
        Entry["AutoApp\n@main, placeholder Settings scene"]
        Model["AppModel\n@Observable state + orchestration"]
        CardModel["Card\none connected card"]
    end

    subgraph CoreLayer ["Core engines (Auto/Core)"]
        Watcher["VolumeWatcher\nmount / unmount"]
        Classifier["VolumeClassifier\ncards vs drives"]
        Scanner["CardScanner\nmedia + camera detection"]
        Index["DriveIndex\nwork folder, name+size keys"]
        Verifier["BackupVerifier\nhash-compares card files"]
        Copy["CopyEngine\nverified copy"]
        Planner["ShootPlanner\nfolder layout, copy jobs, status"]
        ShootFs["ShootFolders\ncreate / adopt, sidecar write"]
        Registry["ShootRegistry / ShootStore\nknown shoots, availability"]
        Coverage["ShootCoverageChecker\nchecksum coverage inside a shoot"]
    end

    subgraph Integrations ["Integrations (Auto/Integrations)"]
        Thumbs["ThumbnailProvider\nQuickLook adapter"]
        Resolve["ResolveClient\nDaVinci Resolve scripting (planned)"]
        Transcode["Transcoder\nAVFoundation / ffmpeg (planned)"]
    end

    subgraph External ["Outside the app"]
        Cards[("Camera cards\n/Volumes/*")]
        Work[("Work folder\nShoot/Video|Photo/Camera/...")]
        ShootReg[("~/Library/Application Support/Auto/shoots.json")]
        DR["DaVinci Resolve"]
    end

    Entry --> Delegate
    Delegate --> Model
    Delegate --> Main
    Delegate --> Settings
    Main --> CardRow
    CardRow --> AddFootage
    CardRow --> NewShoot
    Main --> Model
    CardRow --> Model
    NewShoot --> Model
    Settings --> Model
    Model --> CardModel
    Model --> Watcher
    Watcher --> Classifier
    Model --> Scanner
    Model --> Index
    Model --> Verifier
    Model --> Copy
    Model --> Planner
    Model --> ShootFs
    Model --> Registry
    Model --> Coverage
    Model --> Thumbs
    Watcher -.-> Cards
    Scanner --> Cards
    Verifier --> Cards
    Copy --> Cards
    Index --> Work
    Verifier --> Work
    Copy --> Work
    ShootFs --> Work
    Coverage --> Work
    Registry --> ShootReg
    Model -.-> Transcode
    Model -.-> Resolve
    Transcode -.-> Work
    Resolve -.-> DR

    classDef planned stroke-dasharray: 5 5
    class Transcode,Resolve planned
```

---

## 2. Directory Layout & Module Responsibilities

```text
Auto/                         # repo root
├── Auto.xcodeproj/           # Xcode project (file-system synchronized groups)
│   └── xcshareddata/xcschemes/Auto.xcscheme   # shared scheme: Auto + AutoTests
├── Auto/                     # App target sources
│   ├── App/                  # Entry point + shared state (thin)
│   │   ├── AutoApp.swift     #   @main; placeholder Settings scene (Cmd-comma goes to AppDelegate)
│   │   ├── AppDelegate.swift #   NSStatusItem (left click: window, right click: menu); main window (Settings is a tab)
│   │   ├── AppTab.swift      #   sidebar tabs + light/dark AppearanceMode
│   │   ├── AppModel.swift    #   @Observable state; orchestrates Core (shoots, coverage, addFootage)
│   │   ├── ShootItem.swift   #   ShootItem (registry record + availability, summary, thumbnail); ShootSheetRequest
│   │   ├── ShootCoverageState.swift # CoverageKey (shoot, card) and CoverageState per pair
│   │   └── Card.swift        #   one connected card: volume, files, cameras, phase, copy plan
│   ├── UI/                   # SwiftUI views only, no I/O
│   │   ├── MainView.swift    #   sidebar + floating content panel, switches on AppModel.selectedTab
│   │   ├── Sidebar.swift     #   logo, tabs, New Shoot button, account row (appearance menu)
│   │   ├── MediaView.swift   #   Media tab: stats, cards, Shoots grid, drives
│   │   ├── ShootTile.swift   #   one shoot in the grid: thumbnail, counts, offline/missing state, actions
│   │   ├── EditPlaceholderView.swift # empty Video Edit / Photo Edit tabs
│   │   ├── Theme.swift       #   adaptive color tokens, SurfaceCard, PrimaryPillButtonStyle
│   │   ├── CardRow.swift     #   per-card header, phase content and actions, Add to Shoot menu, per-camera day chips; static StatusDot
│   │   ├── CardBrowserView.swift # read-only Finder-style card browser (icons/list, locations sidebar); opened by clicking a card
│   │   ├── DayChip.swift     #   recording-day chip, shared by CardRow and the New Shoot sheet
│   │   ├── NewShootView.swift#   sheet: create mode (name, date, location) or add-footage mode
│   │   ├── AddFootageSheet.swift #   add a card's footage to a shoot: card picker, completeness banner, Add N files
│   │   └── SettingsView.swift#   Settings tab; "Soon" rows persist values nothing reads yet
│   ├── Core/                 # pure, testable engines, no SwiftUI
│   │   ├── VolumeWatcher.swift     #   NSWorkspace mount notifications, refresh off main
│   │   ├── VolumeClassifier.swift  #   card vs work/backup drive vs ignored volume
│   │   ├── VolumeIdentity.swift    #   card / volume identity (volume UUID + normalized path)
│   │   ├── MediaTypes.swift        #   extensions → MediaKind, skipped folders
│   │   ├── MediaFile.swift         #   MediaFile, MediaKind, Camera models
│   │   ├── CardScanner.swift       #   enumerate media, camera detection, shoot date
│   │   ├── DriveIndex.swift        #   work-folder media grouped by name+size
│   │   ├── BackupVerifier.swift    #   checksum-compares card files with drive candidates
│   │   ├── CopyEngine.swift        #   verified copy with cancel
│   │   ├── ShootDays.swift         #   recording days per camera (ShootDays.byCamera)
│   │   ├── ShootSelection.swift    #   (camera, day) include-set for a shoot; unselected files stay on the card
│   │   ├── ShootPlanner.swift      #   shoot folder naming, planned folder rows, copy jobs, destination checks (checkDestination/createDirectories), CardPhase, StatusAggregator
│   │   ├── Shoot.swift             #   Shoot model (id, name, day, folder)
│   │   ├── ShootSidecar.swift      #   `.auto-shoot.json` codec, versioned (v1)
│   │   ├── ShootFolders.swift      #   classify names/folders, create shoots (exclusive mkdir, sidecar write), adopt
│   │   ├── ShootRegistry.swift     #   registry records, ShootStore (load/save/quarantine), availability, discovery
│   │   ├── ShootCoverage.swift     #   checksum coverage of a card's day inside a shoot folder (cancellable, off main)
│   │   ├── CardBrowser.swift #   groups card files: Not Backed Up / per shoot (deepest folder wins) / Backed Up Elsewhere
│   │   ├── ShootSummary.swift      #   shoot counts + representative file
│   │   └── MainThreadProbe.swift   #   records whether instrumented engines ran on main (tests assert it)
│   ├── Integrations/         # adapters behind protocols; faked in tests
│   │   ├── ThumbnailProvider.swift #   protocol: preview image for a media file
│   │   ├── QLThumbnailProvider.swift # QuickLookThumbnailing adapter
│   │   └── (planned, Phase 3) Resolve / transcoder adapters
│   └── Assets.xcassets
├── AutoTests/                # Swift Testing target (hosted in Auto.app)
│   ├── Support/FixtureCard.swift   #   builds a fake card in a temp dir
│   └── *Tests.swift          #   one file per Core engine, plus AppModelTests
├── .claude/agents/           # Routed subagents: scout (haiku), architect (opus),
│                             #   implementer (sonnet), reviewer (opus), docs-keeper (haiku)
├── .claude/skills/           # Claude Code skills
│   ├── engine-builder/       #   how to add a Core engine / pipeline step
│   ├── rapid-sprint/         #   scope + pacing against ROADMAP.md
│   └── release-readiness/    #   pre-release verification checklist
├── ARCHITECTURE.md           # this file
├── CLAUDE.md                 # Claude Code instructions
├── ROADMAP.md                # phases, status, backlog, decisions
└── README.md
```

| Layer | May depend on | Must not |
| :--- | :--- | :--- |
| `UI` | `App` (via `@Environment(AppModel.self)`) | Touch files, volumes, processes |
| `App` | `Core`, `Integrations` | Contain copy or pipeline logic itself |
| `Core` | Foundation, CryptoKit, ImageIO, AVFoundation; AppKit/DiskArbitration in `VolumeWatcher` only | Import SwiftUI or reference `AppModel` |
| `Integrations` | Foundation, `Process`, QuickLookThumbnailing | Be called directly from views |

---

## 3. Data & Interaction Flow

```mermaid
sequenceDiagram
    autonumber
    actor User
    participant Watcher as VolumeWatcher
    participant Model as AppModel
    participant Scanner as CardScanner
    participant Index as DriveIndex
    participant Verify as BackupVerifier
    participant UI as MainView / CardRow / sheets
    participant Folders as ShootFolders
    participant Coverage as ShootCoverageChecker
    participant Copy as CopyEngine

    Watcher->>Model: Card mounted (/Volumes/X)
    Model->>Scanner: scan(volume)
    Scanner-->>Model: media files, cameras, shoot date
    Model->>Index: build(work folder), when the work drive is ready
    Index-->>Model: candidates keyed by name+size
    Model->>Verify: triage files, hash candidates (cached by drive mtime)
    Verify-->>Model: matched / missing per file
    alt every file matched by hash
        Model->>UI: Status = backed (green)
    else files missing
        Model->>UI: Status = unbacked, offer Add to Shoot or New Shoot
        alt New Shoot (name, date, location)
            User->>UI: Enter name, pick date and location
            UI->>Model: createShoot(name, date, parent)
            Model->>Folders: create: exclusive mkdir (parent must exist), sidecar O_EXCL temp, RENAME_EXCL
            Folders-->>Model: Shoot (sidecar written)
            Model->>Model: save registry (serialized)
        else Add to Shoot (existing shoot, same or other card)
            User->>UI: Pick shoot, check files in the shoot's date
            UI->>Model: addFootage(shoot, card, selection)
            Model->>Coverage: fresh coverage (checksum, only inside the shoot folder)
            Coverage-->>Model: copies per card file
            Model->>Model: re-read sidecar, plan only files not in the shoot
            Model->>Model: create Video/Photo/<camera> inside the shoot
            Model->>Copy: run(jobs), each destination re-checked
            loop each file
                Copy->>Copy: stream to unique O_EXCL partial, hash while reading
                Copy->>Copy: F_FULLFSYNC, re-read uncached, compare hashes
                Copy->>Copy: renamex_np RENAME_EXCL to final name
                Copy-->>Model: progress
            end
            Copy-->>Model: outcome (copied keys, failures)
            Model->>Coverage: re-check coverage for the shoot and card
        end
        Model->>Verify: re-verify card files (verified copies in any online shoot count)
        Model->>UI: Status = backed, or Not backed up (unselected files remain missing)
    end
```

The Phase 3 pipeline (organize → proxies → Resolve project) is not built yet and is not in these diagrams.

---

## 4. Technology Stack

| Concern | Choice | Rationale |
| :--- | :--- | :--- |
| UI | SwiftUI windows hosted by an AppKit `AppDelegate` with an `NSStatusItem` | The status item opens a real window instead of a dropdown. `MenuBarExtra` was dropped; SwiftUI's `openSettings` is unreliable from an accessory-app menu, so AppDelegate routes Cmd-comma to the Settings tab of the main window. |
| State | `@Observable` `AppModel`, injected with `.environment` | Modern Observation; less boilerplate than Backed's `ObservableObject`/Combine. |
| Concurrency | Swift concurrency; default `MainActor` isolation, heavy work `nonisolated` | Keeps UI correct by default while copying runs off-main. |
| Volume detection | `NSWorkspace` mount/unmount notifications; `FileManager.mountedVolumeURLs` on refresh, off the main actor | Auto-detect cards on insert; generation guard drops stale refreshes. |
| Copy verification | Streamed CryptoKit hash on write, `F_FULLFSYNC`, uncached read-back (`F_NOCACHE`) hash compare (xxHash later for speed) | Backed's proven approach, hardened: verify what is on disk before marking backed. |
| Metadata | ImageIO (EXIF), AVFoundation (QuickTime), Sony XML sidecars | Camera model / serial detection, carried over from Backed. |
| Proxies | AVFoundation export (ffmpeg optional) | No bundled dependency for the default path. |
| Resolve | DaVinci Resolve scripting API via `Process` (Python) | Same API the `davinci-resolve` MCP uses. Studio for external scripting. |
| Tests | Swift Testing | Parameterized tests, clean `#expect` diagnostics. |
| Persistence | `UserDefaults` for settings (work folder, auto-open, appearance); the drive index is rebuilt by scanning the work folder; known shoots in `~/Library/Application Support/Auto/shoots.json`; each shoot's identity in `.auto-shoot.json` in its folder | Simple, no database. A persisted, resumable index is Phase 4. The registry is a list of known shoots; the sidecar makes a shoot findable after a relocate or rescan. |

---

## 5. Resiliency & Failure Defense

1. **Read-only sources:** Auto never writes to, renames or deletes anything on a card.
2. **Verify before trust:** A card is backed up only when every file has a checksum-identical copy on the work drive or in an online registered shoot (`BackupVerifier`). Shoot coverage (`ShootCoverageChecker`) reads only inside the shoot folder and never counts card files. Name and size only pick candidates. Copies stream into a unique `O_EXCL` partial, are flushed with `F_FULLFSYNC`, re-read uncached, and are hashed again before they count.
3. **Never overwrite:** The final name is claimed with `renamex_np(RENAME_EXCL)`, so an existing file is never replaced. A name collision gets a unique suffix instead. An identical file from an earlier run is kept.
4. **Fixture cards (the "mock mode"):**
   - Tests build a fake card in a temp directory (DCIM / PRIVATE/M4ROOT layouts, tiny media files and sidecars) via `AutoTests/Support/FixtureCard.swift`.
   - For manual runs, launch with `-AutoFixtureCard <path>` (UserDefaults launch argument) to treat a folder as a mounted card. The window also opens at launch, since no mount event fires for it.
5. **Integration fallbacks:** *(Phase 3, planned)* If Resolve isn't running or scripting is unavailable, the Resolve step reports "skipped: Resolve unavailable" and the ingest still counts as a success. Pipeline steps are independent and re-runnable.
6. **Cancellation:** Copy and verification runs are cancellable. A failed or cancelled copy removes its partial file, so nothing half-written is left under a final name.
7. **Destination checks:** Before any folder is created and again before each copy, the destination must resolve (symlinks resolved through the nearest existing ancestor) to inside the work folder, must not be on a card, and must not have a file where a folder should be (`ShootPlanner.checkDestination` / `createDirectories`). Path containment is lexical. Dangling symlinks are rejected, and the work folder itself is never created: if it is missing (drive unplugged), New Shoot and Copy stop with an error.
8. **Shoot folders:** `ShootFolders` applies the same rules. The chosen parent must exist and is never created, each folder is made with an exclusive mkdir, and the sidecar is written with `O_EXCL` and `RENAME_EXCL` through a directory fd, after a card check. An existing folder is adopted only through the explicit "Use this folder". Forgetting a shoot removes its registry entry only. A corrupt registry is kept as `shoots.json.corrupt-<ts>`, never overwritten.

---

## 6. Development & Milestone Protocol

Phases and their checklists live in [ROADMAP.md](ROADMAP.md). In summary:

- **Phase 1: Foundation.** Menu bar shell, settings, work folder, test target. *(done)*
- **Phase 2: Ingest parity with Backed.** Card detection, scanning, verified copy, shoot folders. *(engines and app wiring landed; manual end-to-end test pending)*
- **Phase 3: Editing pipeline.** Organize, proxies, Resolve project setup.
- **Phase 4: Polish & release.** Notifications, history, signing/notarization.
