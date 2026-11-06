import AppKit

/// The sections in the main window's sidebar.
enum AppTab: String, CaseIterable, Identifiable {
    case media, videoEdit, photoEdit, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .media: "Media"
        case .videoEdit: "Video Edit"
        case .photoEdit: "Photo Edit"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .media: "photo.on.rectangle.angled"
        case .videoEdit: "film"
        case .photoEdit: "camera.aperture"
        case .settings: "gearshape"
        }
    }
}

/// Light/dark preference. `.system` follows macOS.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
