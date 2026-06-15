import SwiftUI

// MARK: - SidebarView
// Settings sidebar with API key, system prompt, model picker, and action buttons

struct SidebarView: View {
    @ObservedObject var vm: ChatViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Sidebar header with collapse button
            header

            // API Key
            apiKeySection

            // System Prompt
            systemPromptSection

            // Routing Mode
            chatModeSection

            // Model Picker (single-model mode only)
            if vm.chatMode == .single {
                modelPickerSection
            }

            if vm.chatMode == .fusion {
                fusionPanelSection
            }

            // Action buttons
            actionButtons

            Spacer()
        }
        .padding(14)
        .frame(width: 260)
        .background(Color.lrmBackground2.opacity(0.6))
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            MetalText("SETTINGS")
            Spacer()
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { vm.sidebarVisible = false } }) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.lrmMuted)
                    .padding(6)
            }
            .buttonStyle(PlainButtonStyle())
            .help("Hide sidebar")
            .accessibilityLabel("Hide sidebar")
        }
        .padding(.bottom, 4)
    }

    // MARK: - API Key

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            MetalText("API KEY")
            LRMSecureField(text: Binding(
                get: { KeychainHelper.shared.get(key: "OpenRouterAPIKey") ?? "" },
                set: { newValue in
                    let ok = KeychainHelper.shared.set(newValue, for: "OpenRouterAPIKey")
                    if !ok && !newValue.isEmpty {
                        vm.showingKeychainAlert = true
                    }
                }
            ))
            .frame(height: 28)
        }
    }

    // MARK: - System Prompt

    private var systemPromptSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            MetalText("SYSTEM PROMPT")
            LRMTextEditor(text: $vm.systemPrompt, placeholder: "You are a helpful assistant...")
                .frame(minHeight: 60, maxHeight: 100)
        }
    }

    // MARK: - Chat Mode

    private var chatModeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            MetalText("MODE")
            HStack(spacing: 6) {
                ForEach(RouterManager.ChatMode.allCases, id: \.self) { mode in
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            vm.chatMode = mode
                        }
                    }) {
                        VStack(spacing: 3) {
                            Image(systemName: mode.icon)
                                .font(.system(size: 12, weight: .bold))
                            Text(mode.displayName.uppercased())
                                .font(.system(size: 9, weight: .black, design: .monospaced))
                        }
                        .foregroundColor(vm.chatMode == mode ? .white : .lrmText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            (vm.chatMode == mode ? Color.lrmAccent : Color.lrmSurface)
                                .clipShape(ChamferShape(cornerSize: 7))
                        )
                        .overlay(
                            ChamferShape(cornerSize: 7)
                                .stroke(vm.chatMode == mode ? Color.lrmAccent.opacity(0.8) : Color.lrmBorder, lineWidth: 1)
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help(mode.helpText)
                }
            }
            Text(vm.chatMode.helpText)
                .font(.system(size: 10))
                .foregroundColor(.lrmMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Fusion Panel

    private var fusionPanelSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            MetalText("FREE FUSION PANEL")
            VStack(alignment: .leading, spacing: 3) {
                ForEach(vm.router.config.fusionPanel, id: \.self) { model in
                    Text("• \(ModelNamer.friendlyName(model))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.lrmMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text("Judge: \(ModelNamer.friendlyName(vm.router.config.fusionJudgeModel))")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.lrmAccent)
                    .padding(.top, 2)
            }
            .padding(8)
            .background(Color.lrmSurface.opacity(0.7).clipShape(ChamferShape(cornerSize: 7)))
            .overlay(ChamferShape(cornerSize: 7).stroke(Color.lrmBorder, lineWidth: 1))
        }
    }

    // MARK: - Model Picker

    private var modelPickerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            MetalText("MODEL")
            Picker("Model", selection: $vm.selectedModel) {
                Text("Auto (\(ModelNamer.friendlyName(vm.router.config.default)))").tag("")
                ForEach(vm.router.config.fallbackOrder, id: \.self) { model in
                    Text(ModelNamer.friendlyName(model)).tag(model)
                }
            }
            .pickerStyle(.menu)
            .accentColor(.lrmAccent)
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        VStack(spacing: 8) {
            MetalButton("Roster Builder…", variant: .primary) {
                vm.showingRosterBuilder = true
            }

            MetalButton("Run Tool…", variant: .metal) {
                vm.showingToolModal = true
            }

            MetalButton("Clear Chat", variant: .ghost) {
                vm.clearChat()
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
struct SidebarView_Previews: PreviewProvider {
    static var previews: some View {
        SidebarView(vm: ChatViewModel())
            .background(Color.lrmBackground)
            .frame(width: 280)
    }
}
#endif
