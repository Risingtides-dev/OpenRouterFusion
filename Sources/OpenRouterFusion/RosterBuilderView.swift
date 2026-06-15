import SwiftUI

// MARK: - RosterBuilderView
// Full-screen model browser + roster builder for creating fusion presets

struct RosterBuilderView: View {
    @ObservedObject var catalog: ModelCatalog
    @ObservedObject var presetStore: PresetStore
    @Binding var isPresented: Bool
    var onSelect: (FusionPreset) -> Void

    @State private var searchText = ""
    @State private var roster: [OpenRouterModel] = []
    @State private var judgeModel: OpenRouterModel?
    @State private var presetName = ""
    @State private var showFreeOnly = true
    @State private var selectedTab: Tab = .browse

    enum Tab: String, CaseIterable {
        case browse = "Browse"
        case roster = "Roster"
        case presets = "Presets"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.lrmBorder)
            tabBar
            Divider().background(Color.lrmBorder)

            switch selectedTab {
            case .browse:
                browseTab
            case .roster:
                rosterTab
            case .presets:
                presetsTab
            }
        }
        .background(Color.lrmBackground)
        .frame(minWidth: 700, minHeight: 500)
        .onAppear {
            if roster.isEmpty {
                // Pre-populate from current config
                let config = RouterManager().config
                roster = config.fusionPanel.compactMap { id in
                    catalog.models.first { $0.id == id }
                }
                judgeModel = catalog.models.first { $0.id == config.fusionJudgeModel }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.lrmAccent)
            Text("FUSION ROSTER BUILDER")
                .font(.system(size: 12, weight: .black, design: .monospaced))
                .foregroundColor(.lrmTextStrong)
            Spacer()
            Text("\(roster.count) models")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.lrmMuted)
            Button("Done") { isPresented = false }
                .buttonStyle(.borderedProminent)
                .tint(.lrmAccent)
        }
        .padding(12)
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { tab in
                Button(action: { selectedTab = tab }) {
                    Text(tab.rawValue)
                        .font(.system(size: 11, weight: selectedTab == tab ? .bold : .medium, design: .monospaced))
                        .foregroundColor(selectedTab == tab ? .lrmAccent : .lrmMuted)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(selectedTab == tab ? Color.lrmAccent.opacity(0.1) : Color.clear)
                }
                .buttonStyle(PlainButtonStyle())
            }
            Spacer()
        }
        .background(Color.lrmSurface.opacity(0.3))
    }

    // MARK: - Browse Tab

    private var browseTab: some View {
        VStack(spacing: 0) {
            // Search + filters
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.lrmMuted)
                TextField("Search models...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                Toggle("Free only", isOn: $showFreeOnly)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 10))
            }
            .padding(8)
            .background(Color.lrmSurface.opacity(0.3))

            Divider().background(Color.lrmBorder)

            // Model list
            ScrollView {
                LazyVStack(spacing: 2) {
                    let filtered = showFreeOnly ? catalog.search(searchText).filter { $0.isFree } : catalog.search(searchText)
                    ForEach(filtered) { model in
                        ModelRow(
                            model: model,
                            isInRoster: roster.contains(where: { $0.id == model.id }),
                            onToggle: { toggleModel(model) }
                        )
                    }
                }
                .padding(4)
            }
        }
    }

    // MARK: - Roster Tab

    private var rosterTab: some View {
        VStack(spacing: 0) {
            // Save bar
            HStack(spacing: 8) {
                TextField("Preset name...", text: $presetName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(6)
                    .background(Color.lrmSurface.clipShape(ChamferShape(cornerSize: 6)))
                    .overlay(ChamferShape(cornerSize: 6).stroke(Color.lrmBorder, lineWidth: 0.5))

                Button(action: savePreset) {
                    Label("Save", systemImage: "square.and.arrow.down")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                }
                .buttonStyle(.borderedProminent)
                .tint(.lrmAccent)
                .disabled(presetName.isEmpty || roster.isEmpty)
            }
            .padding(8)

            Divider().background(Color.lrmBorder)

            // Judge picker
            HStack(spacing: 8) {
                Text("JUDGE")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundColor(.lrmMuted)
                Picker("Judge", selection: $judgeModel) {
                    Text("None").tag(nil as OpenRouterModel?)
                    ForEach(catalog.allModelsSorted) { model in
                        Text(model.friendlyName).tag(model as OpenRouterModel?)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 300)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider().background(Color.lrmBorder)

            // Roster list
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(Array(roster.enumerated()), id: \.element.id) { idx, model in
                        HStack(spacing: 8) {
                            Text("\(idx + 1)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(.lrmMuted)
                                .frame(width: 20)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.friendlyName)
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.lrmText)
                                Text(model.id)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.lrmMuted)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Text(model.contextTier)
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(model.contextWindow >= 1_000_000 ? .green : .lrmMuted)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.lrmSurface.clipShape(RoundedRectangle(cornerRadius: 3)))

                            Text(model.isFree ? "FREE" : "$")
                                .font(.system(size: 9, weight: .black, design: .monospaced))
                                .foregroundColor(model.isFree ? .green : .orange)

                            Button(action: { removeModel(model) }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(.lrmDanger.opacity(0.6))
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.lrmSurface.opacity(0.5).clipShape(ChamferShape(cornerSize: 6)))
                    }
                }
                .padding(8)
            }
        }
    }

    // MARK: - Presets Tab

    private var presetsTab: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(presetStore.presets) { preset in
                    PresetCard(
                        preset: preset,
                        catalog: catalog,
                        onSelect: {
                            loadPreset(preset)
                            selectedTab = .roster
                        },
                        onDelete: { presetStore.delete(preset) }
                    )
                }
            }
            .padding(12)
        }
    }

    // MARK: - Actions

    private func toggleModel(_ model: OpenRouterModel) {
        if let idx = roster.firstIndex(where: { $0.id == model.id }) {
            roster.remove(at: idx)
        } else {
            roster.append(model)
        }
    }

    private func removeModel(_ model: OpenRouterModel) {
        roster.removeAll { $0.id == model.id }
    }

    private func savePreset() {
        let preset = FusionPreset(
            name: presetName,
            models: roster.map { $0.id },
            judgeModel: judgeModel?.id ?? "openrouter/owl-alpha"
        )
        presetStore.save(preset)
        presetName = ""
    }

    private func loadPreset(_ preset: FusionPreset) {
        roster = preset.models.compactMap { id in
            catalog.models.first { $0.id == id }
        }
        judgeModel = catalog.models.first { $0.id == preset.judgeModel }
        presetName = preset.name
    }
}

// MARK: - ModelRow

struct ModelRow: View {
    let model: OpenRouterModel
    let isInRoster: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Image(systemName: isInRoster ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundColor(isInRoster ? .lrmAccent : .lrmMuted)

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.lrmText)
                        .lineLimit(1)
                    Text(model.id)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.lrmMuted)
                        .lineLimit(1)
                }

                Spacer()

                Text(model.contextTier)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(model.contextWindow >= 1_000_000 ? .green : .lrmMuted)

                Text(model.isFree ? "FREE" : "$")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundColor(model.isFree ? .green : .orange)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isInRoster ? Color.lrmAccent.opacity(0.05) : Color.clear)
            .clipShape(ChamferShape(cornerSize: 5))
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - PresetCard

struct PresetCard: View {
    let preset: FusionPreset
    let catalog: ModelCatalog
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(preset.name)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.lrmTextStrong)
                Spacer()
                Button("Load") { onSelect() }
                    .buttonStyle(.borderedProminent)
                    .tint(.lrmAccent)
                    .controlSize(.mini)
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundColor(.lrmDanger)
                }
                .buttonStyle(PlainButtonStyle())
            }

            if !preset.description.isEmpty {
                Text(preset.description)
                    .font(.system(size: 10))
                    .foregroundColor(.lrmMuted)
            }

            HStack(spacing: 4) {
                ForEach(preset.models.prefix(5), id: \.self) { modelId in
                    Text(friendlyName(modelId))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.lrmMuted)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.lrmSurface.clipShape(RoundedRectangle(cornerRadius: 3)))
                }
                if preset.models.count > 5 {
                    Text("+\(preset.models.count - 5)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.lrmMuted)
                }
            }
        }
        .padding(10)
        .background(Color.lrmSurface.opacity(0.5).clipShape(ChamferShape(cornerSize: 8)))
        .overlay(ChamferShape(cornerSize: 8).stroke(Color.lrmBorder, lineWidth: 0.5))
    }

    private func friendlyName(_ id: String) -> String {
        let parts = id.split(separator: "/")
        return parts.count > 1 ? String(parts[1]).replacingOccurrences(of: ":free", with: "") : id
    }
}
