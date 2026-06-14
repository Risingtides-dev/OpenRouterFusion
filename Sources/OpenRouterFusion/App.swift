import SwiftUI

@main
struct OpenRouterFusionApp: App {
    @Environment(\.openWindow) private var openWindow
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 800, minHeight: 500)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 700)
        .commands {
            // Replace the default File menu with our clear command
            CommandGroup(after: .newItem) {
                Divider()
                Button("Pi Sessions") {
                    openWindow(id: "pi-sessions")
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                
                Divider()
                Button("Clear Chat") {
                    NotificationCenter.default.post(name: .clearChat, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)

                Button("Toggle Sidebar") {
                    NotificationCenter.default.post(name: .toggleSidebar, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }
        
        Window("Pi Sessions", id: "pi-sessions") {
            SessionsListView()
        }
        .defaultSize(width: 680, height: 500)
        .keyboardShortcut("l", modifiers: [.command, .shift])
    }
}

extension Notification.Name {
    static let clearChat = Notification.Name("clearChat")
    static let toggleSidebar = Notification.Name("toggleSidebar")
}
