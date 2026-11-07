import SwiftUI

/// Settings shown before a photo cull starts: what to cull, how strict, which model, and the prompt.
struct CullSettingsSheet: View {
    @Environment(AppModel.self) private var model
    let shootID: UUID
    let onStart: () -> Void
    let onCancel: () -> Void

    @State private var preflight: (photos: Int, estimate: (low: Double, high: Double, calls: Int))?
    @State private var loaded = false

    private var shootName: String { model.shoots.first { $0.id == shootID }?.record.name ?? "this shoot" }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    criteriaSection(settings: $model.cullSettings)
                    strictnessSection(settings: $model.cullSettings)
                    modelSection(settings: $model.cullSettings)
                    promptSection(settings: $model.cullSettings)
                    advancedSection(settings: $model.cullSettings)
                    reviewSection(settings: $model.cullSettings)
                    if let notice = model.cullBusyNotice() {
                        Label(notice, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.warning)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(24)
            }
            .scrollBounceBehavior(.basedOnSize)
            footer
        }
        .frame(width: 520)
        .frame(maxHeight: 700)
        .background(Theme.panel)
        .task(id: model.cullSettings.model) {
            let result = await model.cullPreflight(shootID: shootID)
            preflight = result
            loaded = true
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Cull \(shootName)").font(.system(size: 20, weight: .semibold))
            Text(summary).font(.callout).foregroundStyle(.secondary)
        }
    }

    private var summary: String {
        guard loaded else { return "Counting photos…" }
        guard let preflight else { return "Couldn't count photos" }
        let photos = Format.count(preflight.photos, "photo", "photos")
        let e = preflight.estimate
        let calls = Format.count(e.calls, "call", "calls")
        return "\(photos) · ~\(calls) · est. \(Self.money(e.low))–\(Self.money(e.high))"
    }

    private static func money(_ value: Double) -> String { "$" + value.formatted(.number.precision(.fractionLength(2))) }

    private func criteriaSection(settings: Binding<CullSettings>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("What to cull")
            SurfaceCard(padding: 12) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(CullCriterion.all) { criterion in
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle(criterion.title, isOn: Binding(
                                get: { settings.wrappedValue.criteria.contains(criterion.id) },
                                set: { on in
                                    if on { settings.wrappedValue.criteria.insert(criterion.id) }
                                    else { settings.wrappedValue.criteria.remove(criterion.id) }
                                }
                            ))
                            Text(criterion.definition)
                                .font(.caption).foregroundStyle(.secondary)
                                .padding(.leading, 20)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func strictnessSection(settings: Binding<CullSettings>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Mode")
            Picker("Mode", selection: settings.mode) {
                ForEach(CullMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(settings.wrappedValue.mode.blurb)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func modelSection(settings: Binding<CullSettings>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Model")
            Picker("Model", selection: settings.model) {
                ForEach(CullModel.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("Sonnet is the best balance of accuracy and cost.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func promptSection(settings: Binding<CullSettings>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader("Prompt")
            DisclosureGroup("Edit prompt") {
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: Binding(
                        get: { settings.wrappedValue.customPrompt(for: settings.wrappedValue.mode) ?? model.cullRunPromptPreview(mode: settings.wrappedValue.mode) },
                        set: { settings.wrappedValue.setCustomPrompt($0, for: settings.wrappedValue.mode) }
                    ))
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 8 * 16 + 12)
                    .background(Theme.surfaceMuted, in: RoundedRectangle(cornerRadius: Theme.rowRadius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius).strokeBorder(Theme.border))
                    HStack(spacing: 6) {
                        if settings.wrappedValue.customPrompt(for: settings.wrappedValue.mode) != nil {
                            Text("Edited ·").foregroundStyle(.secondary)
                            Button("Reset") { settings.wrappedValue.setCustomPrompt(nil, for: settings.wrappedValue.mode) }
                                .buttonStyle(.link)
                        }
                        Spacer()
                    }
                    .font(.caption)
                    HStack(spacing: 6) {
                        Text("Fixed rules live in the cull workspace's CLAUDE.md.")
                            .foregroundStyle(.secondary)
                        Button("Open Workspace") { model.revealCullWorkspace() }
                            .buttonStyle(.link)
                        Spacer()
                    }
                    .font(.caption)
                }
                .padding(.top, 6)
            }
        }
    }

    private func advancedSection(settings: Binding<CullSettings>) -> some View {
        DisclosureGroup("Advanced") {
            VStack(alignment: .leading, spacing: 10) {
                Stepper(value: settings.maxConcurrentCalls, in: 1...4) {
                    Text("Parallel calls: \(settings.wrappedValue.maxConcurrentCalls)")
                }
                HStack {
                    Text("Stop if a run costs more than")
                    Text("$")
                    TextField("Budget", value: settings.maxRunBudgetUSD, format: .number.precision(.fractionLength(0...2)))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Spacer()
                }
            }
            .font(.callout)
            .padding(.top, 6)
        }
    }

    private func reviewSection(settings: Binding<CullSettings>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Review before applying", isOn: settings.reviewBeforeApplying)
            Text("Coming soon. Decisions apply automatically for now.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.leading, 20)
        }
    }

    // MARK: Footer

    private var footer: some View {
        let reason = model.cullBlockReason(shootID: shootID)
        let noCriteria = model.cullSettings.criteria.isEmpty
        return HStack {
            if let reason {
                Text(reason).font(.callout).foregroundStyle(Theme.warning)
            } else if noCriteria {
                Text("Turn on at least one thing to cull.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel", action: onCancel)
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
            Button("Start Cull", action: onStart)
                .buttonStyle(PrimaryPillButtonStyle())
                .frame(width: 160)
                .keyboardShortcut(.defaultAction)
                .disabled(noCriteria || reason != nil)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}
