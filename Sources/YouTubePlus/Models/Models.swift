import Foundation

// MARK: - SponsorBlock

/// SponsorBlock's own notion of what a segment is for, which is separate from
/// what the user has configured the app to *do* about it.
enum SegmentActionType: String, Codable, Sendable {
    case skip, mute, poi, full
}

struct SponsorSegment: Identifiable, Hashable, Sendable {
    var id: String                 // SponsorBlock UUID
    var category: SponsorCategory
    var actionType: SegmentActionType
    var start: TimeInterval
    var end: TimeInterval
    var locked: Bool
    var votes: Int

    var duration: TimeInterval { max(0, end - start) }
    /// A "point of interest" segment marks an instant rather than a range.
    var isPOI: Bool { actionType == .poi || category == .poi_highlight }
    /// A "full" segment labels the entire video; skipping it would skip everything.
    var isFullVideoLabel: Bool { actionType == .full }

    func contains(_ t: TimeInterval) -> Bool { t >= start && t < end }
}

// MARK: - Formatting helpers

enum Format {
    static func timecode(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    static func compactCount(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        switch n {
        case 1_000_000_000...:
            return String(format: "%.1fB", Double(n) / 1_000_000_000)
        case 1_000_000...:
            return String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...:
            return String(format: "%.1fK", Double(n) / 1_000)
        default:
            return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
        }
    }

    /// "2h 14m of sponsors skipped"
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let h = total / 3600, m = (total % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m \(total % 60)s"
    }

    static func relativeDate(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Errors

enum YouTubePlusError: LocalizedError {
    case network(String)
    case parsing(String)

    var errorDescription: String? {
        switch self {
        case .network(let message): return message
        case .parsing(let message): return message
        }
    }
}
