import SwiftUI

/// Settings tab. Sections marked "Soon" are UI only: they persist a value but nothing reads it yet.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    // Placeholders, not wired up yet.
    @AppStorage("settings.launchAtLogin") private var launchAtLogin = false
    @AppStorage("settings.ejectAfterBackup") private var ejectAfterBackup = false
    @AppStorage("settings.soundOnComplete") private var soundOnComplete = true
    @AppStorage("settings.notifyOnComplete") private var notifyOnComplete = true
    @AppStorage("settings.generateProxies") private var generateProxies = true
    @AppStorage("settings.proxyCodec") private var proxyCodec = "ProRes Proxy"
    @AppStorage("settings.proxyResolution") private var proxyResolution = "Half"
    @AppStorage("settings.createResolveProject") private var createResolveProject = true
    @AppStorage("settings.resolveFrameRate") private var resolveFrameRate = "Match footage"
    @AppStorage("settings.groupRawJpeg") private var groupRawJpeg = true
    @AppStorage("settings.convertToDNG") private var convertToDNG = false

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsSection("General") {
                    SettingsRow("Work folder", detail: "Where shoot folders are created.") {
                        HStack(spacing: 8) {
                            Text(model.workRoot?.path ?? "Not set")
                                .foregroundStyle(model.workRoot == nil ? .secondary : .primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 240, alignment: .trailing)
                            Button("Choose…") { model.setWorkRoot() }
                        }
                    }
                    SettingsRow("Open Auto when a card is connected") {
                        Toggle("", isOn: $model.autoOpen).labelsHidden()
                    }
                    SettingsRow("Launch at login", soon: true) {
                        Toggle("", isOn: $launchAtLogin).labelsHidden()
                    }
                }

                SettingsSection("Appearance") {
                    SettingsRow("Theme") {
                        Picker("", selection: $model.appearance) {
                            ForEach(AppearanceMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                }

                SettingsSection("Ingest", soon: true) {
                    SettingsRow("Eject card after a verified backup") {
                        Toggle("", isOn: $ejectAfterBackup).labelsHidden()
                    }
                    SettingsRow("Play a sound when done") {
                        Toggle("", isOn: $soundOnComplete).labelsHidden()
                    }
                    SettingsRow("Notify when a backup finishes") {
                        Toggle("", isOn: $notifyOnComplete).labelsHidden()
                    }
                    SettingsRow("Second backup destination", detail: "Mirror every copy to another drive.") {
                        Button("Choose…") {}.disabled(true)
                    }
                }

                SettingsSection("Video", soon: true) {
                    SettingsRow("Generate proxies") {
                        Toggle("", isOn: $generateProxies).labelsHidden()
                    }
                    SettingsRow("Proxy codec") {
                        menuPicker($proxyCodec, ["ProRes Proxy", "ProRes LT", "H.264", "H.265"])
                    }
                    SettingsRow("Proxy resolution") {
                        menuPicker($proxyResolution, ["Half", "Quarter", "1080p", "720p"])
                    }
                }

                SettingsSection("DaVinci Resolve", soon: true) {
                    SettingsRow("Create a Resolve project after ingest") {
                        Toggle("", isOn: $createResolveProject).labelsHidden()
                    }
                    SettingsRow("Timeline frame rate") {
                        menuPicker($resolveFrameRate, ["Match footage", "23.976", "24", "25", "29.97", "30", "60"])
                    }
                }

                SettingsSection("Photo", soon: true) {
                    SettingsRow("Group RAW + JPEG pairs") {
                        Toggle("", isOn: $groupRawJpeg).labelsHidden()
                    }
                    SettingsRow("Convert RAW to DNG") {
                        Toggle("", isOn: $convertToDNG).labelsHidden()
                    }
                }
            }
            .toggleStyle(.switch)
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func menuPicker(_ selection: Binding<String>, _ options: [String]) -> some View {
        Picker("", selection: selection) {
            ForEach(options, id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let soon: Bool
    @ViewBuilder var content: Content

    init(_ title: String, soon: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        self.soon = soon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 15, weight: .semibold))
                if soon { SoonBadge() }
            }
            SurfaceCard(padding: 0) {
                VStack(spacing: 0) {
                    Group(subviews: content) { rows in
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                            if index > 0 { Divider().padding(.leading, 16) }
                            row
                        }
                    }
                }
            }
        }
    }
}

private struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    var soon = false
    @ViewBuilder var control: Control

    init(_ title: String, detail: String? = nil, soon: Bool = false, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.soon = soon
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 13))
                    if soon { SoonBadge() }
                }
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct SoonBadge: View {
    var body: some View {
        Text("Soon")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.surfaceMuted, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.border))
    }
}

#Preview {
    SettingsView().environment(AppModel())
}
