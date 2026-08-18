import CryptoKit
import Foundation

/// Talks to the SponsorBlock API.
///
/// In privacy mode we query by the first four characters of the SHA-256 hash of
/// the video id, so the server never learns which video is being watched — it
/// returns every video sharing that prefix and we filter locally.
actor SponsorBlockService {
    static let shared = SponsorBlockService()

    private var cache: [String: [SponsorSegment]] = [:]
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// Stable anonymous identifier used when voting. Generated once, kept locally.
    private static let userIDKey = "youtubeplus.sponsorblock.userID"
    static var localUserID: String {
        if let existing = UserDefaults.standard.string(forKey: userIDKey) { return existing }
        let generated = (0..<36).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! }
        let id = String(generated)
        UserDefaults.standard.set(id, forKey: userIDKey)
        return id
    }

    func clearCache() { cache.removeAll() }

    func segments(for videoID: String,
                  categories: [SponsorCategory],
                  server: String,
                  privacyMode: Bool) async throws -> [SponsorSegment] {
        if let cached = cache[videoID] { return cached }
        guard !categories.isEmpty else { return [] }

        let categoryJSON = (try? JSONSerialization.data(withJSONObject: categories.map(\.rawValue)))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"sponsor\"]"
        let actionJSON = "[\"skip\",\"mute\",\"poi\",\"full\"]"
        let root = server.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))

        var components: URLComponents
        if privacyMode {
            let digest = SHA256.hash(data: Data(videoID.utf8))
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            let prefix = String(hex.prefix(4))
            components = URLComponents(string: "\(root)/api/skipSegments/\(prefix)")!
            components.queryItems = [
                URLQueryItem(name: "categories", value: categoryJSON),
                URLQueryItem(name: "actionTypes", value: actionJSON),
            ]
        } else {
            components = URLComponents(string: "\(root)/api/skipSegments")!
            components.queryItems = [
                URLQueryItem(name: "videoID", value: videoID),
                URLQueryItem(name: "categories", value: categoryJSON),
                URLQueryItem(name: "actionTypes", value: actionJSON),
            ]
        }
        guard let url = components.url else { throw YouTubePlusError.network("Bad SponsorBlock server URL") }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { return [] }
        // 404 simply means "no submissions for this video".
        if http.statusCode == 404 { cache[videoID] = []; return [] }
        guard (200..<300).contains(http.statusCode) else {
            throw YouTubePlusError.network("SponsorBlock returned HTTP \(http.statusCode)")
        }

        let raw: [[String: Any]]
        if privacyMode {
            let all = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
            raw = all
                .first { $0["videoID"] as? String == videoID }
                .flatMap { $0["segments"] as? [[String: Any]] } ?? []
        } else {
            raw = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        }

        let segments = raw.compactMap(Self.parse).sorted { $0.start < $1.start }
        cache[videoID] = segments
        return segments
    }

    private static func parse(_ dict: [String: Any]) -> SponsorSegment? {
        guard let bounds = dict["segment"] as? [Double], bounds.count == 2,
              let raw = dict["category"] as? String,
              let category = SponsorCategory(rawValue: raw),
              let uuid = dict["UUID"] as? String
        else { return nil }

        let locked: Bool
        switch dict["locked"] {
        case let value as Int: locked = value == 1
        case let value as Bool: locked = value
        default: locked = false
        }

        let action = (dict["actionType"] as? String)
            .flatMap(SegmentActionType.init(rawValue:)) ?? .skip

        return SponsorSegment(
            id: uuid,
            category: category,
            actionType: action,
            start: bounds[0],
            end: bounds[1],
            locked: locked,
            votes: dict["votes"] as? Int ?? 0
        )
    }

    /// `upvote: false` sends a downvote, which is how a wrong segment gets fixed.
    func vote(segmentID: String, upvote: Bool, server: String) async throws {
        let root = server.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        var components = URLComponents(string: "\(root)/api/voteOnSponsorTime")!
        components.queryItems = [
            URLQueryItem(name: "UUID", value: segmentID),
            URLQueryItem(name: "userID", value: Self.localUserID),
            URLQueryItem(name: "type", value: upvote ? "1" : "0"),
        ]
        guard let url = components.url else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (_, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw YouTubePlusError.network("Vote failed with HTTP \(http.statusCode)")
        }
    }

    /// Global stats for the "time saved" panel in Settings.
    func userStats(server: String) async throws -> (segments: Int, seconds: Double)? {
        let root = server.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        var components = URLComponents(string: "\(root)/api/userInfo")!
        components.queryItems = [
            URLQueryItem(name: "userID", value: Self.localUserID),
            URLQueryItem(name: "values", value: "[\"segmentCount\",\"minutesSaved\"]"),
        ]
        guard let url = components.url else { return nil }
        let (data, _) = try await session.data(from: url)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let count = json["segmentCount"] as? Int ?? 0
        let minutes = json["minutesSaved"] as? Double ?? 0
        return (count, minutes * 60)
    }
}
