import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            LabeledContent("Work folder") {
                HStack {
                    Text(model.workRoot?.path ?? "Not set")
                        .foregroundStyle(model.workRoot == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose…") { model.setWorkRoot() }
                }
            }
            TextField("Date format", text: $model.dateFormat, prompt: Text(ShootPlanner.defaultDateFormat))
            LabeledContent("Example") {
                Text(model.shootFolderName(date: Date(), name: "Brand film")).foregroundStyle(.secondary)
            }
            Toggle("Open Auto when a card is connected", isOn: $model.autoOpen)
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding()
    }
}

#Preview {
    SettingsView().environment(AppModel())
}
