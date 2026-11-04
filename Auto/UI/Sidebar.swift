import SwiftUI

/// Left column of the main window: logo, tabs, the Ingest button and the account row.
struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            logo
                .padding(.bottom, 20)

            VStack(spacing: 4) {
                ForEach(AppTab.allCases) { tab in
                    SidebarRow(tab: tab, selected: model.selectedTab == tab) {
                        model.selectedTab = tab
                    }
                }
            }

            Button {
                model.ingest()
            } label: {
                Label("Ingest", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(PrimaryPillButtonStyle())
            .help(ingestHelp)
            .padding(.top, 20)

            Spacer(minLength: 20)

            AccountRow()
        }
        .padding(.horizontal, 14)
        .padding(.top, 40) // clears the traffic lights
        .padding(.bottom, 14)
        .frame(width: 220)
    }

    private var logo: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.primary)
                Text("a\(Text(".").font(.system(size: 22, weight: .black)).foregroundStyle(Theme.accent))")
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundStyle(Theme.canvas)
                    .offset(y: -2)
            }
            .frame(width: 36, height: 36)
            Text("Auto").font(.system(size: 17, weight: .semibold))
        }
        .padding(.horizontal, 6)
    }

    private var ingestHelp: String {
        guard let card = model.ingestCandidate else { return "Connect a camera card to ingest it." }
        return card.phase == .ready ? "Copy \(card.name) to its shoot folder" : "Set up a shoot for \(card.name)"
    }
}

private struct SidebarRow: View {
    let tab: AppTab
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: tab.symbol)
                    .symbolVariant(selected ? .fill : .none)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 22)
                Text(tab.title)
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                Spacer()
            }
            .foregroundStyle(selected ? .primary : .secondary)
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background {
                RoundedRectangle(cornerRadius: Theme.rowRadius)
                    .fill(selected ? Theme.selection : (hovering ? Theme.selection.opacity(0.5) : .clear))
                    .shadow(color: .black.opacity(selected ? 0.06 : 0), radius: 3, y: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Bottom-left account row. Local user for now; real accounts come later.
private struct AccountRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Theme.accent.gradient)
                Text(model.accountInitials)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text(model.accountName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text("Local account")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Menu {
                Picker("Appearance", selection: $model.appearance) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbol).tag(mode)
                    }
                }
                Divider()
                Button("Settings…", systemImage: "gearshape") { model.selectedTab = .settings }
                Button("Sign In…", systemImage: "person.crop.circle") {}
                    .disabled(true)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(8)
        .background(Theme.selection.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.rowRadius))
    }
}
