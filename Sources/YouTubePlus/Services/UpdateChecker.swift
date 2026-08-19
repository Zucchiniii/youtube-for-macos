import AppKit
import Foundation

/// Checks GitHub Releases for a newer build.
///
/// A launch-time check alone is not much use here: this is the kind of app that
/// gets opened once and left running for weeks, so a version could ship and
/// never be noticed. Checks therefore also run on a slow repeating timer, when
/// the Mac wakes from sleep, and when the app is brought to the front — all
/// funnelled through one throttle so the actual network traffic stays modest.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    struct Release: Equatable {
        var version: String
        var name: String
        var notes: String
        var page: URL
        var download: URL?
    }

    @Published private(set) var available: Release?
    @Published private(set) var isChecking = false
    /// Result of the most recent check, for the Settings window.
    @Published private(set) var status: String?

    private let endpoint = URL(string:
        "https://api.github.com/repos/zucchiniii/youtube-for-macos/releases/latest")!

    /// No more than one network check an hour, however many triggers fire.
    private let minimumInterval: TimeInterval = 3600
    /// How often to look while the app just sits there running.
    private let pollInterval: TimeInterval = 6 * 3600

    private var lastCheck: Date {
        get { UserDefaults.standard.object(forKey: "ytplus.update.lastCheck") as? Date ?? .distantPast }
        set { UserDefaults.standard.set(newValue, forKey: "ytplus.update.lastCheck") }
    }

    /// A version the user asked not to be told about again.
    private var skippedVersion: String? {
        get { UserDefaults.standard.string(forKey: "ytplus.update.skipped") }
        set { UserDefaults.standard.set(newValue, forKey: "ytplus.update.skipped") }
    }

    private var announcedVersion: String?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    // MARK: - Scheduling

    func start() {
        Task { await check(userInitiated: false) }

        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check(userInitiated: false) }
        }
        timer?.tolerance = 600

        let workspace = NSWorkspace.shared.notificationCenter
        observers = [
            // A sleeping Mac's timers do not fire, so waking is its own trigger.
            workspace.addObserver(forName: NSWorkspace.didWakeNotification,
                                  object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.check(userInitiated: false) }
            },
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.check(userInitiated: false) }
            },
        ]
    }

    // MARK: - Checking

    func check(userInitiated: Bool) async {
        if !userInitiated {
            guard Date().timeIntervalSince(lastCheck) > minimumInterval else { return }
        }
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        lastCheck = Date()

        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw AppError.network("No response") }

            // 404 simply means nothing has been released yet.
            if http.statusCode == 404 {
                available = nil
                status = "No releases published yet."
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                throw AppError.network("GitHub returned HTTP \(http.statusCode)")
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let pageString = json["html_url"] as? String,
                  let page = URL(string: pageString)
            else { throw AppError.parsing("Unexpected response from GitHub") }

            let asset = (json["assets"] as? [[String: Any]] ?? [])
                .first { ($0["name"] as? String)?.hasSuffix(".dmg") == true }
                .flatMap { $0["browser_download_url"] as? String }
                .flatMap(URL.init(string:))

            let release = Release(
                version: Self.number(from: tag),
                name: json["name"] as? String ?? tag,
                notes: (json["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                page: page,
                download: asset)

            if Self.isNewer(release.version, than: currentVersion) {
                available = release
                status = "Version \(release.version) is available."
                if !userInitiated { announceIfUnseen(release) }
            } else {
                available = nil
                status = "Up to date (\(currentVersion))."
            }
        } catch {
            status = "Could not check: \(error.localizedDescription)"
        }
    }

    // MARK: - Announcing

    /// Told once per version, not on every check — an update notice that
    /// reappears every six hours is just an interruption.
    private func announceIfUnseen(_ release: Release) {
        guard release.version != skippedVersion,
              release.version != announcedVersion else { return }
        announcedVersion = release.version
        present(release, userInitiated: false)
    }

    func present(_ release: Release, userInitiated: Bool) {
        let alert = NSAlert()
        alert.messageText = "YouTube Plus \(release.version) is available"
        alert.informativeText = release.notes.isEmpty
            ? "You have \(currentVersion)."
            : "You have \(currentVersion).\n\n\(release.notes.prefix(600))"
        alert.addButton(withTitle: "Open Release Page")
        alert.addButton(withTitle: "Later")
        if !userInitiated { alert.addButton(withTitle: "Skip This Version") }

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(release.download ?? release.page)
        case .alertThirdButtonReturn:
            skippedVersion = release.version
        default:
            break
        }
    }

    /// Shows the outcome of a check the user asked for, including "nothing new".
    func checkAndReport() {
        Task {
            await check(userInitiated: true)
            if let release = available {
                present(release, userInitiated: true)
            } else {
                let alert = NSAlert()
                alert.messageText = "You're up to date"
                alert.informativeText = status ?? "YouTube Plus \(currentVersion) is the latest version."
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }

    // MARK: - Versions

    /// Tags get written all sorts of ways — "v2.1", "v.2.1", "release-2.1" —
    /// so everything before the first digit is dropped rather than assuming a
    /// single leading "v".
    static func number(from tag: String) -> String {
        guard let start = tag.firstIndex(where: \.isNumber) else { return tag }
        return String(tag[start...])
    }

    /// Compares dotted version numbers component by component, so 2.10 beats 2.9.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        let b = current.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let left = i < a.count ? a[i] : 0
            let right = i < b.count ? b[i] : 0
            if left != right { return left > right }
        }
        return false
    }
}
