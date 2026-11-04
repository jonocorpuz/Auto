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
| `Auto/AutoApp.swift` | App entry point: `MenuBarExtra` + `Settings` scenes |
| `Auto/AppModel.swift` | Shared `@Observable` app state |
| `Auto/MenuView.swift` | Menu bar popover UI |
| `Auto/SettingsView.swift` | Settings window |
