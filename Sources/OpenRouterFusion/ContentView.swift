import SwiftUI

// MARK: - ContentView
// Thin shell that composes the extracted views and binds to ChatViewModel

struct ContentView: View {
    @StateObject private var vm = ChatViewModel()
    
    // Debouncer for streaming content scroll updates
    private let scrollDebouncer = Debouncer(delay: 0.05)

    var body: some View {
        HStack(spacing: 0) {
            // Left sidebar (collapses when preview is open)
            if vm.sidebarVisible && !vm.showingPreview {
                SidebarView(vm: vm)
                Divider().background(Color.lrmBorder)
            }

            // Chat area
            chatArea

            // Right preview panel (slides in when preview is active)
            if vm.showingPreview, let html = vm.previewHTML {
                Divider().background(Color.lrmBorder)
                PreviewPanelView(
                    htmlContent: html,
                    title: vm.previewTitle,
                    onClose: { vm.closePreview() }
                )
                .frame(minWidth: 320, idealWidth: 480, maxWidth: .infinity)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .background(
            ZStack {
                Color.lrmBackground
                LinearGradient.lrmBackgroundRadial.opacity(0.4)
            }
            .ignoresSafeArea()
        )
        .animation(.easeInOut(duration: 0.25), value: vm.showingPreview)
        .alert("Keychain Error", isPresented: $vm.showingKeychainAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(vm.keychainAlertMessage)
        }
        .sheet(isPresented: $vm.showingToolModal) {
            ToolModalView(command: $vm.toolCommand, onRun: { cmd in vm.runManualTool(cmd) })
        }
        .sheet(isPresented: $vm.showingRosterBuilder) {
            RosterBuilderView(
                catalog: vm.catalog,
                presetStore: vm.presetStore,
                isPresented: $vm.showingRosterBuilder,
                onSelect: { preset in
                    vm.activePreset = preset
                }
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .clearChat)) { _ in
            vm.clearChat()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleSidebar)) { _ in
            withAnimation(.easeInOut(duration: 0.2)) {
                vm.sidebarVisible.toggle()
            }
        }
        .onAppear {
            vm.onAppear()
        }
        .onChange(of: vm.systemPrompt) {
            vm.saveSystemPrompt()
        }
    }

    // MARK: - Chat Area

    private var chatArea: some View {
        VStack(spacing: 0) {
            // Show sidebar toggle when sidebar is hidden and no preview
            if !vm.sidebarVisible && !vm.showingPreview {
                HStack {
                    Button(action: { withAnimation(.easeInOut(duration: 0.2)) { vm.sidebarVisible = true } }) {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.lrmMuted)
                            .padding(8)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("Show sidebar")
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.lrmBackground2.opacity(0.3))
            }

            // Show sidebar toggle when preview is open (so user can bring it back)
            if vm.showingPreview {
                HStack {
                    Button(action: { withAnimation(.easeInOut(duration: 0.2)) { vm.sidebarVisible.toggle() } }) {
                        Image(systemName: vm.sidebarVisible ? "sidebar.left" : "sidebar.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.lrmMuted)
                            .padding(8)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help("Toggle sidebar")
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.lrmBackground2.opacity(0.3))
            }

            if vm.store.messages.isEmpty && !vm.isStreaming {
                EmptyStateView()
            } else {
                ChatLogView(vm: vm, scrollDebouncer: scrollDebouncer)
            }

            Divider().background(Color.lrmBorder)
            ComposerView(vm: vm)
        }
    }
}

// MARK: - Preview

#if DEBUG
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .frame(width: 900, height: 600)
    }
}
#endif
