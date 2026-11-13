import SwiftUI

/// The app's main window: a sidebar of tabs beside a floating content panel.
struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
            VStack(spacing: 0) {
                header
                ThemedDivider()
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.border))
            .shadow(color: .black.opacity(0.05), radius: 12, y: 2)
            .padding([.top, .trailing, .bottom], 10)
        }
        .background(Theme.canvas)
        .ignoresSafeArea()
        .frame(minWidth: 820, minHeight: 540)
        .sheet(isPresented: Binding(
            get: { model.shootSheet != nil },
            set: { if !$0 { model.shootSheet = nil } }
        )) {
            NewShootView()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(model.selectedTab.title)
                .font(.system(size: 20, weight: .semibold))
            Spacer()
            if model.selectedTab == .media {
                HStack(spacing: 6) {
                    StatusDot(color: Color(nsColor: model.status.tint))
                    Text(model.status.label).font(.callout).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.surfaceMuted, in: Capsule())
                if let root = model.workRoot {
                    Label(root.lastPathComponent, systemImage: "folder")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Theme.surfaceMuted, in: Capsule())
                        .help(root.path)
                }
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 60)
    }

    @ViewBuilder private var content: some View {
        switch model.selectedTab {
        case .media:
            MediaView()
        case .videoEdit:
            VideoEditView()
        case .photoEdit:
            PhotoEditView()
        case .settings:
            SettingsView()
        }
    }
}

#Preview {
    MainView().environment(AppModel())
}
