import SwiftUI

/// "Mar 22 · 14" capsule: one recording day and its file count.
struct DayChip: View {
    let day: ShootDay
    var calendar: Calendar = .current

    var body: some View {
        let sameYear = calendar.component(.year, from: day.start) == calendar.component(.year, from: Date())
        let date = sameYear
            ? day.start.formatted(.dateTime.month(.abbreviated).day())
            : day.start.formatted(.dateTime.month(.abbreviated).day().year())
        Text("\(date) · \(day.fileCount)")
            .font(.caption)
            .monospacedDigit()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.surfaceMuted, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.border))
    }
}
