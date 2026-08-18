import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct SettingsView: View {
    var body: some View {
        TabView {
            SponsorBlockSettings()
                .tabItem { Label("SponsorBlock", systemImage: "forward.end.alt") }
            AdSettings()
                .tabItem { Label("Ads", systemImage: "hand.raised") }
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 640, height: 580)
    }
}

// MARK: - SponsorBlock

struct SponsorBlockSettings: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var serverStatus: String?

    var body: some View {
        Form {
            Section {
                Toggle("Enable SponsorBlock", isOn: $settings.s.sponsorBlockEnabled)
                Text("Segment data comes from the community SponsorBlock database.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("What to do with each category") {
                ForEach(SponsorCategory.allCases) { category in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Circle().fill(category.color).frame(width: 9, height: 9)
                            Text(category.label)
                            Spacer()
                            Picker("", selection: Binding(
                                get: { settings.s.action(for: category) },
                                set: { settings.s.categoryActions[category.rawValue] = $0 }
                            )) {
                                ForEach(SegmentAction.allCases) { action in
                                    Label(action.label, systemImage: action.symbol).tag(action)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 180)
                        }
                        Text(category.detail)
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.leading, 17)
                    }
                    .padding(.vertical, 2)
                }
                .disabled(!settings.s.sponsorBlockEnabled)
            }

            Section("Behaviour") {
                LabeledContent("Ignore segments shorter than") {
                    Stepper("\(settings.s.minimumSegmentDuration, specifier: "%.1f")s",
                            value: $settings.s.minimumSegmentDuration, in: 0...30, step: 0.5)
                }
                Toggle("Show a notice when a segment is skipped", isOn: $settings.s.showSkipNotice)
                if settings.s.showSkipNotice {
                    LabeledContent("Notice stays for") {
                        Stepper("\(Int(settings.s.skipNoticeDuration))s",
                                value: $settings.s.skipNoticeDuration, in: 1...30, step: 1)
                    }
                    Toggle("Offer an Unskip button", isOn: $settings.s.allowUnskip)
                }
                Toggle("Mark segments on YouTube's scrub bar", isOn: $settings.s.showSegmentsInTimeline)
                Toggle("Show the segment list under the video", isOn: $settings.s.showSegmentPanel)
                Text("The list appears below the video title, with each segment's time range and a Jump link.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(!settings.s.sponsorBlockEnabled)

            Section("Statistics") {
                LabeledContent("Time saved", value: Format.duration(settings.s.totalSecondsSkipped))
                LabeledContent("Segments skipped", value: "\(settings.s.totalSegmentsSkipped)")
                Toggle("Keep counting", isOn: $settings.s.trackTimeSaved)
                Button("Reset counters") {
                    settings.s.totalSecondsSkipped = 0
                    settings.s.totalSegmentsSkipped = 0
                }
            }

            Section("Server") {
                Toggle("Privacy mode", isOn: $settings.s.sponsorBlockPrivacyMode)
                Text("Queries by a four-character hash prefix, so the server never learns which video you are watching.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("API server", text: $settings.s.sponsorBlockServer)
                HStack {
                    Button("Test connection") { Task { await testServer() } }
                    if let serverStatus {
                        Text(serverStatus).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func testServer() async {
        serverStatus = "Contacting…"
        do {
            _ = try await SponsorBlockService.shared.segments(
                for: "dQw4w9WgXcQ",
                categories: [.sponsor],
                server: settings.s.sponsorBlockServer,
                privacyMode: settings.s.sponsorBlockPrivacyMode)
            serverStatus = "Server responded"
        } catch {
            serverStatus = "Failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Ads

struct AdSettings: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle("Block ads", isOn: $settings.s.blockAds)
            }

            Section("What this does") {
                row("Removes the ad slot",
                    "The ad placements are stripped out of YouTube's player response before its own code reads them, so no ad is ever scheduled. This is what stops the black screen: blocking the ad's network requests alone left the player buffering an ad that would never arrive, for about as long as the ad itself.")
                row("Blocks ad requests",
                    "Ad and ad-tracking hosts are blocked inside WebKit, so those requests never leave your Mac. Banner ads, overlay ads and promoted rows go with them.")
                row("Presses skip",
                    "A fallback for anything that still slips through: the skip button is clicked as soon as it appears, and an unskippable ad is muted and run out at speed.")
                row("Removes Premium prompts",
                    "The “get YouTube without the ads” dialog and its mealbar are dismissed and removed, always — even with ad blocking off.")
            }

            Section("What it cannot do") {
                Text("Ads that YouTube stitches into the video stream itself, from the same servers as the video, are indistinguishable from content and cannot be removed this way. Those are still uncommon, but they exist.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Text("Takes effect on the next page load. Press ⌘R to apply it now.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout.weight(.medium))
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
    }
}

// MARK: - General

struct GeneralSettings: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var message: String?

    var body: some View {
        Form {
            Section("Window") {
                Toggle("Keep the window above others", isOn: $settings.s.alwaysOnTop)
            }

            Section("Page") {
                Toggle("Hide Shorts shelves", isOn: $settings.s.hideShorts)
                Text("Removes the Shorts rows from feeds and the sidebar entry.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Account") {
                Text("Sign in on the page itself, exactly as in a browser. The session is stored on this Mac and persists between launches.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Sign out and clear site data", role: .destructive) {
                    Task {
                        await SiteData.clear()
                        message = "Site data cleared. Press ⌘R to reload."
                    }
                }
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Keyboard") {
                Text("The page keeps YouTube's own shortcuts — space, k, j and l, arrows, f for full screen, c for captions.")
                    .font(.caption).foregroundStyle(.secondary)
                shortcut("⌘1–⌘4", "Home, Subscriptions, History, Watch Later")
                shortcut("⌘← ⌘→", "Back and forward")
                shortcut("⌘R", "Reload")
                shortcut("⌘O", "Open the YouTube link on the clipboard")
                shortcut("⌘⇧B", "Toggle SponsorBlock")
                shortcut("⌘⇧A", "Toggle ad blocking")
            }

            Section("Settings file") {
                HStack {
                    Button("Export…") { export() }
                    Button("Import…") { importSettings() }
                    Spacer()
                    Button("Reset everything", role: .destructive) {
                        settings.resetToDefaults()
                        message = "Settings reset to defaults."
                    }
                }
            }

            Section("About") {
                LabeledContent("YouTube Plus", value: "2.0")
                Text("YouTube in a native macOS window, with SponsorBlock and ad blocking built in. The interface is YouTube's own, so everything works the way you already know.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func shortcut(_ keys: String, _ description: String) -> some View {
        HStack {
            Text(keys)
                .font(.caption.monospaced())
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                .frame(width: 80, alignment: .leading)
            Text(description).font(.caption)
            Spacer()
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "YouTube Plus Settings.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try settings.exportJSON().write(to: url)
            message = "Exported to \(url.lastPathComponent)."
        } catch {
            message = "Export failed: \(error.localizedDescription)"
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try settings.importJSON(Data(contentsOf: url))
            message = "Imported from \(url.lastPathComponent)."
        } catch {
            message = "Import failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Site data

enum SiteData {
    /// Clears cookies and storage, which signs the user out of YouTube.
    static func clear() async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        await store.removeData(ofTypes: types, for: records)
    }
}
