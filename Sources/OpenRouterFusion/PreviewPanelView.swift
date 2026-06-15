import SwiftUI
import WebKit

// MARK: - PreviewPanelView
// Right sidebar that renders HTML content in a WKWebView

struct PreviewPanelView: View {
    let htmlContent: String
    let title: String
    var onClose: () -> Void

    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            Divider().background(Color.lrmBorder)

            // WebView
            ZStack {
                PreviewWebView(htmlContent: htmlContent, isLoading: $isLoading)
                    .background(Color.white)

                if isLoading {
                    VStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading preview…")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.lrmMuted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.lrmBackground.opacity(0.8))
                }
            }
        }
        .background(Color.lrmBackground2)
        .clipShape(ChamferShape(cornerSize: 0))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.lrmAccent)

            Text(title)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.lrmText)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.lrmMuted)
                    .padding(6)
                    .background(Color.lrmSurface.opacity(0.5).clipShape(Circle()))
            }
            .buttonStyle(PlainButtonStyle())
            .help("Close preview")
            .keyboardShortcut("w", modifiers: .command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.lrmBackground2.opacity(0.8))
    }
}

// MARK: - PreviewWebView (NSViewRepresentable wrapper for WKWebView)

struct PreviewWebView: NSViewRepresentable {
    let htmlContent: String
    @Binding var isLoading: Bool

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsMagnification = true
        webView.setValue(false, forKey: "drawsBackground")

        // Load the HTML
        webView.loadHTMLString(htmlContent, baseURL: nil)

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Only reload if content changed
        if context.coordinator.lastLoadedContent != htmlContent {
            context.coordinator.lastLoadedContent = htmlContent
            webView.loadHTMLString(htmlContent, baseURL: nil)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: PreviewWebView
        var lastLoadedContent: String = ""

        init(_ parent: PreviewWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
            }
        }

        // Open external links in default browser instead of inside the preview
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
