import SwiftUI

/// Empty Video Edit / Photo Edit tabs until their pipelines land.
struct EditPlaceholderView: View {
    let tab: AppTab
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: tab.symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
                .frame(width: 72, height: 72)
                .background(Theme.surfaceMuted, in: RoundedRectangle(cornerRadius: 18))
            Text(tab.title).font(.system(size: 17, weight: .semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
