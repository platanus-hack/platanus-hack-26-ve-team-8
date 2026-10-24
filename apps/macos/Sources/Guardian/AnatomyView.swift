import SwiftUI
import WebKit

/// Live numbers from the local agent; nil plays the figure's demo tour.
struct AnatomyState: Encodable, Equatable {
    let connected: Bool
    let monitoring: Bool
    let observations: Int
    let investigating: Bool
    let steps: Int
    let findings: Int
}

/// The "Anatomy of an investigation" figure (packages/figure), shared with the landing page.
struct AnatomyView: NSViewRepresentable {
    let state: AnatomyState?

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        view.loadHTMLString(AnatomyFigure.html, baseURL: nil)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.push(state, to: view)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private var loaded = false
        private var script: String?

        func push(_ state: AnatomyState?, to view: WKWebView) {
            guard let state, let data = try? JSONEncoder().encode(state), let json = String(data: data, encoding: .utf8) else { return }
            let next = "window.arkangel.update(\(json))"
            guard next != script else { return }
            script = next
            if loaded { view.evaluateJavaScript(next) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            if let script { webView.evaluateJavaScript(script) }
        }

        // The figure is a static local document; it never navigates anywhere.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            loaded ? .cancel : .allow
        }
    }
}
