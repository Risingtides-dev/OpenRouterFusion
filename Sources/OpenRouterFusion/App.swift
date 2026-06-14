import SwiftUI

@main
struct OpenRouterFusionApp: App {
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
    }
}

extension Notification.Name {
    static let clearChat = Notification.Name("clearChat")
    static let toggleSidebar = Notification.Name("toggleSidebar")
}
