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
        .task(id: "\(model.cullSettings.model.rawValue)-\(model.cullSettings.mode.rawValue)") {
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
            VStack(spacing: 8) {
                ForEach(CullMode.allCases) { mode in
                    let selected = settings.wrappedValue.mode == mode
                    Button { settings.wrappedValue.mode = mode } label: {
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mode.title).font(.system(size: 13, weight: .semibold))
                                Text(mode.blurb).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected ? Theme.accent : Color.secondary.opacity(0.5))
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
                        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius)
                            .strokeBorder(selected ? Theme.accent : Theme.border, lineWidth: selected ? 2 : 1))
                        .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            if settings.wrappedValue.mode == .selects, loaded, let preflight, preflight.photos > 0 {
                let keep = max(1, Int((Double(preflight.photos) * CullMode.selectsKeepFraction).rounded(.up)))
                Text("Keeps about \(keep) of \(preflight.photos) photos. Rejects are moved to _Rejects and can be undone.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
                promptEditor(settings: settings)
            }
            .font(.callout)
            .padding(.top, 6)
        }
    }

    private func promptEditor(settings: Binding<CullSettings>) -> some View {
        let mode = settings.wrappedValue.mode
        return VStack(alignment: .leading, spacing: 8) {
            Text("Prompt for \(mode.title)").font(.system(size: 13, weight: .semibold))
            TextEditor(text: Binding(
                get: { settings.wrappedValue.customPrompt(for: mode) ?? model.cullRunPromptPreview(mode: mode) },
                set: { settings.wrappedValue.setCustomPrompt($0, for: mode) }
            ))
            .font(.system(size: 12, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(height: 8 * 16 + 12)
            .background(Theme.surfaceMuted, in: RoundedRectangle(cornerRadius: Theme.rowRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius).strokeBorder(Theme.border))
            HStack(spacing: 6) {
                if settings.wrappedValue.customPrompt(for: mode) != nil {
                    Text("Edited ·").foregroundStyle(.secondary)
                    Button("Reset") { settings.wrappedValue.setCustomPrompt(nil, for: mode) }
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
