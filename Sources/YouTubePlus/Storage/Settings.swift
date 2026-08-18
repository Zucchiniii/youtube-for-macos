import Foundation
import SwiftUI

// MARK: - Enumerations

enum SegmentAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case skip, manual, mute, showOnly, ignore
    var id: String { rawValue }
    var label: String {
        switch self {
        case .skip: return "Skip automatically"
        case .manual: return "Show a skip button"
        case .mute: return "Mute audio"
        case .showOnly: return "Show in timeline only"
        case .ignore: return "Ignore"
        }
    }
    var symbol: String {
        switch self {
        case .skip: return "forward.end.fill"
        case .manual: return "hand.tap"
        case .mute: return "speaker.slash"
        case .showOnly: return "eye"
        case .ignore: return "xmark"
        }
    }
}

enum SponsorCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case sponsor
    case selfpromo
    case interaction
    case intro
    case outro
    case preview
    case music_offtopic
    case filler
    case poi_highlight
    case exclusive_access

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sponsor: return "Sponsor"
        case .selfpromo: return "Unpaid / self-promotion"
        case .interaction: return "Interaction reminder"
        case .intro: return "Intermission / intro animation"
        case .outro: return "Endcards / credits"
        case .preview: return "Preview / recap"
        case .music_offtopic: return "Non-music section"
        case .filler: return "Filler tangent"
        case .poi_highlight: return "Highlight"
        case .exclusive_access: return "Exclusive access"
        }
    }

    var detail: String {
        switch self {
        case .sponsor: return "Paid promotion, paid referrals and direct advertisements."
        case .selfpromo: return "Unpaid or self-promotion — merch, donations, other creators."
        case .interaction: return "\"Like, subscribe, hit the bell\" reminders."
        case .intro: return "An interval with no content — pause, static frame, repeating animation."
        case .outro: return "Credits or when endcards appear. Not conclusions with content."
        case .preview: return "A quick recap of previous episodes, or a preview of what's coming."
        case .music_offtopic: return "Only for music videos — sections not part of the song."
        case .filler: return "Tangential scenes added only for filler or humour."
        case .poi_highlight: return "The point in the video most people are looking for."
        case .exclusive_access: return "The creator showcasing a product they got for free."
        }
    }

    var defaultAction: SegmentAction {
        switch self {
        case .sponsor, .selfpromo, .interaction: return .skip
        case .intro, .outro, .preview, .filler: return .manual
        case .music_offtopic: return .skip
        case .poi_highlight: return .showOnly
        case .exclusive_access: return .showOnly
        }
    }

    /// CSS colour for the marks drawn on YouTube's scrub bar.
    var hexColour: String {
        switch self {
        case .sponsor: return "#00d16b"
        case .selfpromo: return "#ffff70"
        case .interaction: return "#cc00ff"
        case .intro: return "#00ffff"
        case .outro: return "#0202ed"
        case .preview: return "#0099d9"
        case .music_offtopic: return "#ff9900"
        case .filler: return "#7300ff"
        case .poi_highlight: return "#ff0078"
        case .exclusive_access: return "#008a5c"
        }
    }

    var color: Color {
        switch self {
        case .sponsor: return Color(red: 0.00, green: 0.82, blue: 0.42)
        case .selfpromo: return Color(red: 1.00, green: 1.00, blue: 0.44)
        case .interaction: return Color(red: 0.80, green: 0.00, blue: 1.00)
        case .intro: return Color(red: 0.00, green: 1.00, blue: 1.00)
        case .outro: return Color(red: 0.00, green: 0.13, blue: 1.00)
        case .preview: return Color(red: 0.01, green: 0.60, blue: 0.85)
        case .music_offtopic: return Color(red: 1.00, green: 0.60, blue: 0.00)
        case .filler: return Color(red: 0.45, green: 0.00, blue: 1.00)
        case .poi_highlight: return Color(red: 1.00, green: 0.00, blue: 0.47)
        case .exclusive_access: return Color(red: 0.02, green: 0.55, blue: 0.36)
        }
    }
}

// MARK: - Settings

struct AppSettings: Codable, Equatable, Sendable {

    // ── SponsorBlock ──────────────────────────────────────────────────────
    var sponsorBlockEnabled: Bool = true
    var sponsorBlockServer: String = "https://sponsor.ajay.app"
    var sponsorBlockPrivacyMode: Bool = true
    var categoryActions: [String: SegmentAction] = Dictionary(
        uniqueKeysWithValues: SponsorCategory.allCases.map { ($0.rawValue, $0.defaultAction) }
    )
    var minimumSegmentDuration: Double = 0
    var showSkipNotice: Bool = true
    var skipNoticeDuration: Double = 5
    var showSegmentsInTimeline: Bool = true
    var showSegmentPanel: Bool = true
    var allowUnskip: Bool = true
    var trackTimeSaved: Bool = true
    var totalSecondsSkipped: Double = 0
    var totalSegmentsSkipped: Int = 0

    // ── Ads ───────────────────────────────────────────────────────────────
    var blockAds: Bool = true

    // ── Window and page ───────────────────────────────────────────────────
    var alwaysOnTop: Bool = false
    var hideShorts: Bool = false

    func action(for category: SponsorCategory) -> SegmentAction {
        categoryActions[category.rawValue] ?? category.defaultAction
    }

    init() {}

    /// Decoded field by field so that a settings file written by an older
    /// version — one that predates a newly added preference — still loads.
    /// The synthesised decoder would throw on the missing key and quietly
    /// reset every other preference along with it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) .flatMap { $0 } ?? fallback
        }
        sponsorBlockEnabled = v(.sponsorBlockEnabled, d.sponsorBlockEnabled)
        sponsorBlockServer = v(.sponsorBlockServer, d.sponsorBlockServer)
        sponsorBlockPrivacyMode = v(.sponsorBlockPrivacyMode, d.sponsorBlockPrivacyMode)
        categoryActions = v(.categoryActions, d.categoryActions)
        minimumSegmentDuration = v(.minimumSegmentDuration, d.minimumSegmentDuration)
        showSkipNotice = v(.showSkipNotice, d.showSkipNotice)
        skipNoticeDuration = v(.skipNoticeDuration, d.skipNoticeDuration)
        showSegmentsInTimeline = v(.showSegmentsInTimeline, d.showSegmentsInTimeline)
        showSegmentPanel = v(.showSegmentPanel, d.showSegmentPanel)
        allowUnskip = v(.allowUnskip, d.allowUnskip)
        trackTimeSaved = v(.trackTimeSaved, d.trackTimeSaved)
        totalSecondsSkipped = v(.totalSecondsSkipped, d.totalSecondsSkipped)
        totalSegmentsSkipped = v(.totalSegmentsSkipped, d.totalSegmentsSkipped)
        blockAds = v(.blockAds, d.blockAds)
        alwaysOnTop = v(.alwaysOnTop, d.alwaysOnTop)
        hideShorts = v(.hideShorts, d.hideShorts)
    }
}

// MARK: - Store

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    private static let key = "skipper.settings.v1"

    @Published var s: AppSettings {
        didSet { save() }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            s = decoded
        } else {
            s = AppSettings()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(s) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    func resetToDefaults() {
        s = AppSettings()
    }

    func exportJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(s)
    }

    func importJSON(_ data: Data) throws {
        s = try JSONDecoder().decode(AppSettings.self, from: data)
    }
}
