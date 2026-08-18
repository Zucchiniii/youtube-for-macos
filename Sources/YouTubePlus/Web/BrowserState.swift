import SwiftUI
import WebKit

/// Window-level state: what the web view is showing and what the menus can do.
@MainActor
final class BrowserState: ObservableObject {
    @Published var pageTitle = "YouTube"
    @Published var currentVideoID: String?
    @Published var segmentCount = 0
    // Deliberately not @Published: these change four times a second, and
    // republishing them re-evaluates the view — which re-pushed preferences
    // into the page and had it rebuilding the SponsorBlock panel constantly.
    var isPlaying = false
    var isShowingAd = false
    var currentTime: TimeInterval = 0

    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isPlayerFullscreen = false

    private weak var webView: WKWebView?
    var onOptionsChanged: (() -> Void)?

    let homeURL = URL(string: "https://www.youtube.com/")!

    private var fullscreenObservers: [NSObjectProtocol] = []
    private var keyMonitor: Any?

    init() {
        observeWindowFullscreen()
        installNavigationShortcuts()
    }

    /// Whether the page currently has a text field focused, reported by the
    /// injected script. Command-arrow must stay caret movement while typing.
    var isEditingText = false

    /// Back and forward are matched on key code rather than character: the
    /// character for a given key depends on the keyboard layout, and on a
    /// Swedish layout the key that types "[" on a US keyboard types "å", so a
    /// ⌘[ shortcut simply never fires. Command-arrow is layout independent and
    /// is the standard macOS back/forward besides. WebKit would otherwise
    /// consume these itself, so they are intercepted ahead of it.
    private func installNavigationShortcuts() {
        let leftArrow: UInt16 = 123
        let rightArrow: UInt16 = 124

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.modifierFlags.contains(.command),
                  !event.modifierFlags.contains(.option),
                  event.keyCode == leftArrow || event.keyCode == rightArrow
            else { return event }

            return MainActor.assumeIsolated {
                guard !self.isEditingText else { return event }
                if event.keyCode == leftArrow {
                    guard self.canGoBack else { return event }
                    self.goBack()
                } else {
                    guard self.canGoForward else { return event }
                    self.goForward()
                }
                return nil
            }
        }
    }

    func attach(_ webView: WKWebView) { self.webView = webView }

    func updateNavigationState(_ webView: WKWebView) {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        if let title = webView.title, !title.isEmpty { pageTitle = title }
    }

    /// Re-sends preferences to the page after a settings change.
    func settingsChanged() { onOptionsChanged?() }

    // MARK: - Navigation

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }
    func goHome() { open(homeURL) }

    func open(_ url: URL) { webView?.load(URLRequest(url: url)) }

    func openSubscriptions() { open(URL(string: "https://www.youtube.com/feed/subscriptions")!) }
    func openHistory() { open(URL(string: "https://www.youtube.com/feed/history")!) }
    func openWatchLater() { open(URL(string: "https://www.youtube.com/playlist?list=WL")!) }
    func openTrending() { open(URL(string: "https://www.youtube.com/feed/trending")!) }

    /// Opens whatever YouTube link is on the clipboard.
    @discardableResult
    func openClipboardLink() -> Bool {
        let pasted = NSPasteboard.general.string(forType: .string) ?? ""
        if let id = Self.videoID(from: pasted),
           let url = URL(string: "https://www.youtube.com/watch?v=\(id)") {
            open(url)
            return true
        }
        if let url = URL(string: pasted.trimmingCharacters(in: .whitespacesAndNewlines)),
           url.host?.contains("youtube.com") == true {
            open(url)
            return true
        }
        return false
    }

    func copyCurrentLink(withTime: Bool) {
        guard let id = currentVideoID else { return }
        var link = "https://www.youtube.com/watch?v=\(id)"
        if withTime, currentTime > 1 { link += "&t=\(Int(currentTime))s" }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
    }

    func openCurrentInBrowser() {
        guard let url = webView?.url else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Player commands

    func togglePlayPause() { evaluate("window.__ytplus && __ytplus.togglePlay()") }

    func seek(by delta: TimeInterval) {
        evaluate("window.__ytplus && __ytplus.seek(\(max(0, currentTime + delta)))")
    }

    private func evaluate(_ javascript: String) {
        webView?.evaluateJavaScript(javascript, completionHandler: nil)
    }

    // MARK: - Full screen

    func toggleFullscreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    private func observeWindowFullscreen() {
        let center = NotificationCenter.default
        fullscreenObservers = [
            center.addObserver(forName: NSWindow.didEnterFullScreenNotification,
                               object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.isPlayerFullscreen = true }
            },
            center.addObserver(forName: NSWindow.didExitFullScreenNotification,
                               object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.isPlayerFullscreen = false }
            },
        ]
    }

    /// Accepts a watch URL, a youtu.be link, a /shorts/ link or a bare id.
    static func videoID(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count == 11,
           trimmed.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) {
            return trimmed
        }
        guard let components = URLComponents(string: trimmed) else { return nil }
        if let v = components.queryItems?.first(where: { $0.name == "v" })?.value, v.count == 11 {
            return v
        }
        if components.host?.contains("youtu.be") == true {
            let id = components.path.replacingOccurrences(of: "/", with: "")
            return id.count == 11 ? id : nil
        }
        if components.path.contains("/shorts/") || components.path.contains("/embed/") {
            let id = components.path.split(separator: "/").last.map(String.init) ?? ""
            return id.count == 11 ? id : nil
        }
        return nil
    }
}
