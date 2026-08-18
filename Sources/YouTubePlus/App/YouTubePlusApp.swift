import SwiftUI

@main
struct YouTubePlusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var settings = SettingsStore.shared
    @StateObject private var browser = BrowserState()

    var body: some Scene {
        WindowGroup {
            YouTubeView(browser: browser)
                .toolbar {
                    ToolbarItemGroup(placement: .navigation) {
                        Button {
                            browser.goBack()
                        } label: {
                            Label("Back", systemImage: "chevron.backward")
                        }
                        .disabled(!browser.canGoBack)
                        .help("Back (⌘←)")

                        Button {
                            browser.goForward()
                        } label: {
                            Label("Forward", systemImage: "chevron.forward")
                        }
                        .disabled(!browser.canGoForward)
                        .help("Forward (⌘→)")
                    }
                }
                .environmentObject(settings)
                .environmentObject(browser)
                .background(WindowConfigurator(alwaysOnTop: settings.s.alwaysOnTop))
                .frame(minWidth: 900, minHeight: 560)
                .navigationTitle(browser.pageTitle)
                .task { await AdBlocker.prepare() }
                .onChange(of: settings.s) { _, _ in browser.settingsChanged() }
        }
        .commands { commands }

        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(browser)
        }
    }

    @CommandsBuilder
    private var commands: some Commands {
        // The page keeps YouTube's own single-key shortcuts (space, k, j/l, f,
        // c, arrows), so nothing here claims a bare letter.
        CommandGroup(replacing: .newItem) {
            Button("Open YouTube Link from Clipboard") {
                if !browser.openClipboardLink() { NSSound.beep() }
            }
            .keyboardShortcut("o", modifiers: [.command])
        }

        CommandGroup(after: .toolbar) {
            Button("Back") { browser.goBack() }
                .keyboardShortcut(.leftArrow, modifiers: [.command])
                .disabled(!browser.canGoBack)
            Button("Forward") { browser.goForward() }
                .keyboardShortcut(.rightArrow, modifiers: [.command])
                .disabled(!browser.canGoForward)
            Button("Reload") { browser.reload() }
                .keyboardShortcut("r", modifiers: [.command])
            Divider()
            Toggle("Always on Top", isOn: $settings.s.alwaysOnTop)
        }

        CommandMenu("Go") {
            Button("Home") { browser.goHome() }
                .keyboardShortcut("1", modifiers: [.command])
            Button("Subscriptions") { browser.openSubscriptions() }
                .keyboardShortcut("2", modifiers: [.command])
            Button("History") { browser.openHistory() }
                .keyboardShortcut("3", modifiers: [.command])
            Button("Watch Later") { browser.openWatchLater() }
                .keyboardShortcut("4", modifiers: [.command])
            Divider()
            Button("Copy Link to This Video") { browser.copyCurrentLink(withTime: false) }
                .disabled(browser.currentVideoID == nil)
            Button("Copy Link at Current Time") { browser.copyCurrentLink(withTime: true) }
                .disabled(browser.currentVideoID == nil)
            Button("Open in Default Browser") { browser.openCurrentInBrowser() }
        }

        CommandMenu("SponsorBlock") {
            Toggle("Enable SponsorBlock", isOn: $settings.s.sponsorBlockEnabled)
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Toggle("Block Ads", isOn: $settings.s.blockAds)
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Divider()
            Text(segmentSummary)
            Text("Saved \(Format.duration(settings.s.totalSecondsSkipped)) across \(settings.s.totalSegmentsSkipped) segments")
            Divider()
            Toggle("Mark Segments on the Scrub Bar", isOn: $settings.s.showSegmentsInTimeline)
            Toggle("Show a Notice When Skipping", isOn: $settings.s.showSkipNotice)
        }

        CommandGroup(replacing: .help) {
            Button("YouTube Plus Help") {
                NSWorkspace.shared.open(URL(fileURLWithPath: helpFilePath))
            }
        }
    }

    private var segmentSummary: String {
        guard browser.currentVideoID != nil else { return "No video playing" }
        switch browser.segmentCount {
        case 0: return "No segments for this video"
        case 1: return "1 segment on this video"
        default: return "\(browser.segmentCount) segments on this video"
        }
    }

    private var helpFilePath: String {
        Bundle.main.path(forResource: "README", ofType: "md") ?? "/"
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Window helpers

/// Reaches the hosting NSWindow so window-level settings can be applied.
struct WindowConfigurator: NSViewRepresentable {
    let alwaysOnTop: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { apply(to: view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { apply(to: view.window) }
    }

    private func apply(to window: NSWindow?) {
        guard let window else { return }
        window.level = alwaysOnTop ? .floating : .normal
    }
}
