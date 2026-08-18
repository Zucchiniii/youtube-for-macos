import Foundation
import WebKit

/// Network-level ad blocking for the embedded player.
///
/// WebKit compiles these rules once and applies them inside its own networking
/// stack, so ad requests never leave the machine. This complements the in-page
/// script, which clicks skip buttons and removes overlay ads that arrive over
/// the same connections as the video itself.
enum AdBlocker {
    private static let identifier = "youtubeplus-ad-rules-v1"

    /// Compiled list, cached after the first build so views can attach it
    /// without waiting.
    nonisolated(unsafe) private static var cached: WKContentRuleList?

    static var compiled: WKContentRuleList? { cached }

    /// Compiles the rules ahead of first use. Safe to call repeatedly.
    @discardableResult
    static func prepare() async -> WKContentRuleList? {
        if let cached { return cached }
        guard let store = WKContentRuleListStore.default() else { return nil }

        if let existing = try? await store.contentRuleList(forIdentifier: identifier) {
            cached = existing
            return existing
        }
        let list = try? await store.compileContentRuleList(
            forIdentifier: identifier, encodedContentRuleList: rules)
        cached = list
        return list
    }

    /// Ad and ad-tracking endpoints. Deliberately narrow: YouTube serves media
    /// from googlevideo.com and its app code from ytimg.com, so neither host is
    /// touched — blocking them would break playback rather than ads.
    /// Ad and ad-tracking endpoints.
    ///
    /// Deliberately narrow. googlevideo.com (the media itself) and ytimg.com
    /// (the app code) are never touched, and neither are YouTube's own
    /// `/api/stats/*` or `/ptracking` endpoints: the player waits on those
    /// before it starts, so blocking them makes every video slow to begin.
    private static let rules = """
    [
      {"trigger": {"url-filter": "^https?://[^/]*doubleclick\\.net/"},
       "action": {"type": "block"}},
      {"trigger": {"url-filter": "^https?://[^/]*googlesyndication\\.com/"},
       "action": {"type": "block"}},
      {"trigger": {"url-filter": "^https?://[^/]*googleadservices\\.com/"},
       "action": {"type": "block"}},
      {"trigger": {"url-filter": "^https?://[^/]*youtube\\.com/pagead/"},
       "action": {"type": "block"}},
      {"trigger": {"url-filter": "^https?://[^/]*google\\.com/pagead/"},
       "action": {"type": "block"}},
      {"trigger": {"url-filter": ".*", "if-domain": ["*youtube.com"]},
       "action": {"type": "css-display-none",
                  "selector": "#player-ads, #masthead-ad, ytd-ad-slot-renderer, ytd-in-feed-ad-layout-renderer, .ytp-ad-overlay-container, .ytp-ad-overlay-slot, ytd-promoted-sparkles-web-renderer, ytd-display-ad-renderer, ytd-companion-slot-renderer, yt-mealbar-promo-renderer, ytd-mealbar-promo-renderer"}}
    ]
    """
}
