# Auto

A macOS menu bar app.

## Requirements

- macOS 26+
- Xcode 26+

## Run

Open `Auto.xcodeproj` and press ⌘R. Auto shows up in the menu bar (there's no Dock icon).

## Structure

| File | Purpose |
| --- | --- |
| `Auto/App/AutoApp.swift` | App entry point: `MenuBarExtra` + `Settings` scenes |
| `Auto/App/AppModel.swift` | Shared `@Observable` app state |
| `Auto/UI/MenuView.swift` | Menu bar popover UI |
| `Auto/UI/SettingsView.swift` | Settings window |
| `AutoTests/` | Swift Testing suite |

## Tests

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -project Auto.xcodeproj -scheme Auto -destination 'platform=macOS'
```

See [ARCHITECTURE.md](ARCHITECTURE.md) and [ROADMAP.md](ROADMAP.md) for design and plans.
