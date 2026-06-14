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
            
            // Chat Mode Toggle
            chatModeSection
            
            // Model Picker (only in single mode)
            if vm.chatMode == .single {
                modelPickerSection
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
            LRMTextEditor(text: $vm.systemPrompt, placeholder: "You are a helpful assistant…")
                .frame(minHeight: 60, maxHeight: 100)
        }
    }
    
    // MARK: - Chat Mode Toggle

    private var chatModeSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            MetalText("MODE")
            HStack(spacing: 4) {
                ForEach(RouterManager.ChatMode.allCases, id: \.self) { mode in
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            vm.chatMode = mode
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: mode.icon)
                                .font(.system(size: 10, weight: .bold))
                            Text(mode.displayName)
                                .font(.system(size: 10, weight: .bold))
                        }
                        .foregroundColor(vm.chatMode == mode ? .white : .lrmText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            (vm.chatMode == mode ? Color.lrmAccent : Color.lrmSurface)
                                .clipShape(ChamferShape(cornerSize: 4))
                        )
                        .overlay(
                            ChamferShape(cornerSize: 4)
                                .stroke(vm.chatMode == mode ? Color.lrmAccent.opacity(0.8) : Color.lrmBorder, lineWidth: 1)
                        )
                        .clipShape(ChamferShape(cornerSize: 4))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
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
