import SwiftUI
import WebKit

/// YouTube Plus is YouTube's own site, with SponsorBlock and ad blocking layered on.
///
/// Everything the user sees — the home feed, search, subscriptions, the player,
/// the scrub bar, quality, captions, full screen — is YouTube's own interface,
/// so it behaves exactly as expected and never goes stale when YouTube changes.
/// YouTube Plus adds what YouTube does not have: sponsor-segment skipping, ad
/// blocking, and a native window with real macOS menus.
struct YouTubeView: NSViewRepresentable {
    @ObservedObject var browser: BrowserState

    func makeCoordinator() -> Coordinator { Coordinator(browser: browser) }

    func makeNSView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "ytplus")
        // At document start so segment marks and ad handling are live before
        // YouTube finishes booting; again at the end because it rewrites the DOM.
        for time in [WKUserScriptInjectionTime.atDocumentStart, .atDocumentEnd] {
            controller.addUserScript(WKUserScript(source: PageScript.source,
                                                  injectionTime: time,
                                                  forMainFrameOnly: true))
        }
        if SettingsStore.shared.s.blockAds, let rules = AdBlocker.compiled {
            controller.add(rules)
        }

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // Lets YouTube's own full-screen button work.
        configuration.preferences.isElementFullscreenEnabled = true
        // Persistent, so signing in to YouTube sticks across launches.
        configuration.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = Self.userAgent
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true

        context.coordinator.attach(webView)
        browser.attach(webView)
        webView.load(URLRequest(url: browser.homeURL))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Nothing to do per update: preferences are pushed when the page
        // finishes loading and whenever settings actually change.
    }

    /// A stock desktop Safari agent: YouTube serves its full desktop site, and
    /// Google's sign-in accepts it rather than showing the "browser may not be
    /// secure" block page.
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/18.3 Safari/605.1.15"

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        private let browser: BrowserState
        private weak var webView: WKWebView?
        private var currentVideoID: String?
        private var segmentTask: Task<Void, Never>?
        private var navigationObservers: [NSKeyValueObservation] = []

        init(browser: BrowserState) { self.browser = browser }

        func attach(_ webView: WKWebView) {
            self.webView = webView
            // YouTube navigates in-page, which pushes history entries without
            // firing the navigation delegate, so the back/forward buttons are
            // driven by KVO instead.
            navigationObservers = [
                webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] view, _ in
                    Task { @MainActor in self?.browser.canGoBack = view.canGoBack }
                },
                webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] view, _ in
                    Task { @MainActor in self?.browser.canGoForward = view.canGoForward }
                },
                webView.observe(\.title, options: [.new]) { [weak self] view, _ in
                    Task { @MainActor in
                        if let title = view.title, !title.isEmpty {
                            self?.browser.pageTitle = title
                        }
                    }
                },
            ]
            if Self.debugLogging {
                webView.configuration.userContentController.addUserScript(
                    WKUserScript(source: "window.__ytplusDebug = true;",
                                 injectionTime: .atDocumentStart, forMainFrameOnly: true))
            }
            browser.onOptionsChanged = { [weak self] in self?.pushOptions() }
        }

        // MARK: Navigation

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            browser.updateNavigationState(webView)
            pushOptions()
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            browser.updateNavigationState(webView)
        }

        /// Keeps browsing inside Google's own sites; anything else opens in the
        /// user's real browser.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow); return
            }
            if Self.isInternal(url) {
                decisionHandler(.allow)
            } else if navigationAction.navigationType == .linkActivated {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }

        private static func isInternal(_ url: URL) -> Bool {
            guard let host = url.host else { return true }
            return host.hasSuffix("youtube.com")
                || host.hasSuffix("youtu.be")
                || host.hasSuffix("google.com")
                || host.hasSuffix("googleusercontent.com")
                || host.hasSuffix("ggpht.com")
                || host.hasSuffix("gstatic.com")
        }

        /// target="_blank" links (and YouTube's own popouts) load in place
        /// instead of silently doing nothing.
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url {
                if Self.isInternal(url) {
                    webView.load(URLRequest(url: url))
                } else {
                    NSWorkspace.shared.open(url)
                }
            }
            return nil
        }

        // MARK: Messages from the page

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }

            switch type {
            case "video":
                handleVideoChange(id: body["id"] as? String,
                                  title: body["title"] as? String)

            case "state":
                if Self.debugLogging, let diag = body["diag"] as? [String: Any] {
                    Self.logDiagnostics(diag)
                }
                browser.isPlaying = body["playing"] as? Bool ?? false
                browser.currentTime = body["time"] as? Double ?? 0
                browser.isShowingAd = body["ad"] as? Bool ?? false

            case "skipped":
                let saved = body["saved"] as? Double ?? 0
                guard SettingsStore.shared.s.trackTimeSaved else { break }
                SettingsStore.shared.s.totalSecondsSkipped += saved
                SettingsStore.shared.s.totalSegmentsSkipped += 1

            case "unskipped":
                let saved = body["saved"] as? Double ?? 0
                guard SettingsStore.shared.s.trackTimeSaved else { break }
                SettingsStore.shared.s.totalSecondsSkipped -= saved
                SettingsStore.shared.s.totalSegmentsSkipped -= 1

            case "focus":
                browser.isEditingText = body["editing"] as? Bool ?? false

            case "vote":
                guard let uuid = body["uuid"] as? String else { break }
                let up = body["up"] as? Bool ?? true
                let server = SettingsStore.shared.s.sponsorBlockServer
                Task {
                    try? await SponsorBlockService.shared.vote(
                        segmentID: uuid, upvote: up, server: server)
                }

            default:
                break
            }
        }

        /// Set YTPLUS_DEBUG=1 to trace page state on stderr.
        static let debugLogging = ProcessInfo.processInfo.environment["YTPLUS_DEBUG"] == "1"
        private static var lastLog = Date.distantPast

        private static func logDiagnostics(_ diag: [String: Any]) {
            guard Date().timeIntervalSince(lastLog) > 2 else { return }
            lastLog = Date()
            let fields = diag.keys.sorted().map { "\($0)=\(diag[$0]!)" }.joined(separator: " ")
            FileHandle.standardError.write(Data("[page] \(fields)\n".utf8))
        }

        // MARK: SponsorBlock

        private func handleVideoChange(id: String?, title: String?) {
            browser.currentVideoID = id
            browser.pageTitle = title ?? "YouTube"
            browser.segmentCount = 0

            segmentTask?.cancel()
            guard let id else {
                send("__ytplus.setSegments([])")
                return
            }

            let settings = SettingsStore.shared.s
            guard settings.sponsorBlockEnabled else {
                send("__ytplus.setSegments([])")
                return
            }

            segmentTask = Task { [weak self] in
                let active = SponsorCategory.allCases.filter { settings.action(for: $0) != .ignore }
                guard !active.isEmpty,
                      let segments = try? await SponsorBlockService.shared.segments(
                        for: id,
                        categories: active,
                        server: settings.sponsorBlockServer,
                        privacyMode: settings.sponsorBlockPrivacyMode)
                else { return }

                guard !Task.isCancelled, let self else { return }
                let usable = segments.filter {
                    $0.isPOI || $0.duration >= settings.minimumSegmentDuration
                }
                self.browser.segmentCount = usable.count
                if Self.debugLogging {
                    FileHandle.standardError.write(
                        Data("[swift] fetched \(usable.count) segments for \(id)\n".utf8))
                }
                self.sendSegments(usable, settings: settings)
            }
        }

        private func sendSegments(_ segments: [SponsorSegment], settings: AppSettings) {
            let payload = segments.map { segment -> [String: Any] in
                [
                    "uuid": segment.id,
                    "start": segment.start,
                    "end": segment.end,
                    "category": segment.category.rawValue,
                    "label": segment.category.label,
                    "colour": segment.category.hexColour,
                    "action": settings.action(for: segment.category).rawValue,
                    "actionLabel": settings.action(for: segment.category).label,
                    "poi": segment.isPOI,
                    "full": segment.isFullVideoLabel,
                ]
            }
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else { return }
            send("__ytplus.setSegments(\(json))")
        }

        private var lastOptionsJSON = ""

        /// Pushes the current preferences into the page, skipping the call when
        /// nothing has changed — the page rebuilds its panel on each one.
        func pushOptions() {
            let settings = SettingsStore.shared.s
            let options: [String: Any] = [
                "enabled": settings.sponsorBlockEnabled,
                "showNotice": settings.showSkipNotice,
                "noticeSeconds": settings.skipNoticeDuration,
                "allowUnskip": settings.allowUnskip,
                "showBar": settings.showSegmentsInTimeline,
                "showPanel": settings.showSegmentPanel,
                "blockAds": settings.blockAds,
                "hideShorts": settings.hideShorts,
                "quality": settings.preferredQuality.rawValue,
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: options),
                  let json = String(data: data, encoding: .utf8),
                  json != lastOptionsJSON else { return }
            lastOptionsJSON = json
            send("__ytplus.setOptions(\(json))")
        }

        private func send(_ javascript: String) {
            webView?.evaluateJavaScript("window.__ytplus && \(javascript)", completionHandler: nil)
        }
    }
}
