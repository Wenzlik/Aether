import SwiftUI
import AppKit
import AetherCore

/// The native macOS **Settings** window (⌘, / "Aether ▸ Settings…"), surfaced
/// via the `Settings` scene: Accounts, Playback defaults, Appearance (watched
/// display), and About. All bound to the same stores the iOS app uses, so a
/// preference set on either platform carries over.
struct MacSettingsView: View {
    var session: MacSession
    /// `true` when shown inside the main window's detail pane (sidebar → Settings)
    /// rather than the standalone Settings scene — then it fills the pane and the
    /// app-level dark/tint/locale already apply, so we don't re-set them or pin a
    /// window-sized frame.
    var embedded = false

    var body: some View {
        TabView {
            GeneralSettings(session: session)
                .tabItem { Label("General", systemImage: "gearshape") }
            AccountsSettings(session: session)
                .tabItem { Label("Accounts", systemImage: "person.2") }
            PlaybackSettings(prefs: session.playbackPrefs)
                .tabItem { Label("Playback", systemImage: "play.rectangle") }
            AppearanceSettings(prefs: session.playbackPrefs, appearance: session.appearance)
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .modifier(SettingsChrome(embedded: embedded, locale: session.appLocale,
                                 colorScheme: session.appearance.preference.colorScheme))
    }
}

/// Window-only chrome for the standalone Settings scene; in-pane it inherits the
/// app's appearance and fills.
private struct SettingsChrome: ViewModifier {
    let embedded: Bool
    let locale: Locale
    let colorScheme: ColorScheme?
    func body(content: Content) -> some View {
        if embedded {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            content
                .frame(width: 480, height: 380)
                .tint(AetherMacTheme.accent)
                .preferredColorScheme(colorScheme)
                .environment(\.locale, locale)
        }
    }
}

private struct AccountsSettings: View {
    var session: MacSession
    @State private var signIn: SignIn?

    private enum SignIn: String, Identifiable { case plex, jellyfin; var id: String { rawValue } }

    var body: some View {
        Form {
            Section("Plex") {
                if session.isPlexConnected {
                    ForEach(session.plexServerNames, id: \.self) { name in
                        LabeledContent("Server", value: name)
                    }
                    Button("Sign Out of Plex", role: .destructive) {
                        Task { await session.signOutPlex() }
                    }
                } else {
                    LabeledContent("Status", value: "Not connected")
                    Button("Connect Plex…") { signIn = .plex }
                }
            }
            Section("Jellyfin") {
                if let name = session.jellyfinServerName {
                    LabeledContent("Server", value: name)
                    Button("Sign Out of Jellyfin", role: .destructive) {
                        Task { await session.signOutJellyfin() }
                    }
                } else {
                    LabeledContent("Status", value: "Not connected")
                    Button("Connect Jellyfin…") { signIn = .jellyfin }
                }
            }
            Section("Other Sources") {
                LabeledContent("SMB / NAS", value: "Coming soon")
                LabeledContent("Local Library", value: "Set up in General")
            }
        }
        .formStyle(.grouped)
        .sheet(item: $signIn) { which in
            switch which {
            case .plex:     PlexSignInSheet(session: session) { signIn = nil }
            case .jellyfin: JellyfinSignInSheet(session: session) { signIn = nil }
            }
        }
    }
}

/// General app settings — currently the UI language (System / English / Čeština),
/// applied live via `\.locale` so the app switches without a restart, matching
/// iOS. Strings localize from the Mac String Catalog (Localizable.xcstrings).
private struct GeneralSettings: View {
    @Bindable var session: MacSession
    /// Local draft for the TMDb key. Editing a property on the @Observable
    /// `session` directly re-rendered the whole app on every keystroke, which
    /// dropped the field's focus after one character — so it was effectively
    /// impossible to type a key. Editing a local @State and committing on
    /// Return/blur keeps focus and only touches `session` once.
    @State private var tmdbDraft = ""
    /// TMDb key editor state: the key is entered in a SecureField, verified
    /// against TMDb before saving, then hidden (only "Configured" shows).
    @State private var isEditingKey = false
    @State private var keyCheck: KeyCheck = .idle
    private enum KeyCheck { case idle, checking, valid, invalid, network }

    var body: some View {
        Form {
            Section("Language") {
                Picker("Language", selection: $session.appLanguage) {
                    Text("System").tag("system")
                    Text("English").tag("en")
                    Text("Čeština").tag("cs")
                }
                Text("Changes the app's language immediately. Some text may still appear in English until fully translated.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Local Library") {
                ForEach(session.localFolders, id: \.self) { url in
                    HStack {
                        Label(url.lastPathComponent, systemImage: "folder")
                        Spacer()
                        Button(role: .destructive) {
                            session.removeLocalFolder(url)
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                if let status = session.localScanStatus {
                    HStack(spacing: 6) {
                        if status == "Scanning…" { ProgressView().controlSize(.small) }
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button("Add Folder…", systemImage: "plus") { addFolder() }
                if !session.localFolders.isEmpty {
                    Button("Rescan", systemImage: "arrow.clockwise") { session.rescanLocalLibrary() }
                }
                Text("Pick folders on this Mac or a mounted network share. Aether scans them for movies and shows and adds them to your library.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Metadata") {
                if session.isTMDBConfigured && !isEditingKey {
                    // Configured → never show the key, just its state.
                    LabeledContent("TMDb API Key") {
                        Label("Configured", systemImage: "checkmark.seal.fill")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.green)
                    }
                    Button("Change Key") { tmdbDraft = ""; keyCheck = .idle; isEditingKey = true }
                    if !session.tmdbToken.isEmpty {
                        Button("Remove Custom Key", role: .destructive) {
                            session.tmdbToken = ""
                            session.rescanLocalLibrary()
                            keyCheck = .idle
                        }
                    }
                } else {
                    SecureField("TMDb API Key", text: $tmdbDraft)
                        .onSubmit { Task { await verifyAndSave() } }
                        .onChange(of: tmdbDraft) { _, _ in if keyCheck != .checking { keyCheck = .idle } }
                    switch keyCheck {
                    case .checking:
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Verifying with TMDb…").font(.caption).foregroundStyle(.secondary)
                        }
                    case .invalid:
                        Label("Invalid key — TMDb rejected it.", systemImage: "xmark.octagon.fill")
                            .font(.caption).foregroundStyle(.red)
                    case .network:
                        Label("Couldn't reach TMDb — check your connection.", systemImage: "wifi.exclamationmark")
                            .font(.caption).foregroundStyle(.orange)
                    case .valid, .idle:
                        EmptyView()
                    }
                    HStack {
                        Button(keyCheck == .checking ? "Verifying…" : "Verify & Save") {
                            Task { await verifyAndSave() }
                        }
                        .disabled(tmdbDraft.trimmingCharacters(in: .whitespaces).isEmpty || keyCheck == .checking)
                        if keyCheck == .network {
                            Button("Save Anyway") { saveKey(tmdbDraft) }
                        }
                        if session.isTMDBConfigured {
                            Button("Cancel") { isEditingKey = false; keyCheck = .idle; tmdbDraft = "" }
                        }
                    }
                }
                Text("Used to fetch posters and descriptions for your local library. Leave the built-in key, or paste your own from themoviedb.org — it's verified against TMDb before saving, then hidden.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // Netflix availability (#360) — opt-in, mirrors iOS Settings.
            Section("Streaming Services") {
                Toggle("Show Netflix availability", isOn: Binding(
                    get: { session.streamingPreferences.netflixAvailabilityEnabled },
                    set: { session.streamingPreferences.netflixAvailabilityEnabled = $0; session.watchAvailability.invalidate() }
                ))
                if session.streamingPreferences.netflixAvailabilityEnabled {
                    Toggle("Show Netflix-only titles", isOn: Binding(
                        get: { session.streamingPreferences.showNetflixOnlyTitles },
                        set: { session.streamingPreferences.showNetflixOnlyTitles = $0 }
                    ))
                    Picker("Region", selection: Binding(
                        get: { session.streamingPreferences.region ?? "" },
                        set: { session.streamingPreferences.region = $0.isEmpty ? nil : $0; session.watchAvailability.invalidate() }
                    )) {
                        Text("Follow device").tag("")
                        ForEach(Self.regions, id: \.self) { code in
                            Text(regionName(code)).tag(code)
                        }
                    }
                    if !session.isTMDBConfigured {
                        Label("Add a TMDb key above to enable availability lookups.", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Text("Mark titles you own that are also on Netflix, and surface Netflix-only titles in Discover and Search. Aether links out — it never streams Netflix. Availability data by JustWatch.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Region codes Netflix availability can be checked against (mirrors iOS).
    private static let regions = [
        "US", "GB", "CA", "AU", "IE",
        "CZ", "SK", "DE", "AT", "CH", "FR", "ES", "IT", "NL", "BE", "PL",
        "SE", "NO", "DK", "FI", "PT", "BR", "MX", "JP", "KR", "IN"
    ]
    private func regionName(_ code: String) -> String {
        session.appLocale.localizedString(forRegionCode: code) ?? code
    }

    /// Verify the entered key against TMDb, then save + hide it. Invalid keys are
    /// rejected; a network error offers "Save Anyway".
    private func verifyAndSave() async {
        let key = tmdbDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        keyCheck = .checking
        switch await session.validateTMDbKey(key) {
        case .valid:        saveKey(key)
        case .invalid:      keyCheck = .invalid
        case .networkError, .empty: keyCheck = .network
        }
    }

    private func saveKey(_ raw: String) {
        session.tmdbToken = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        session.rescanLocalLibrary()
        tmdbDraft = ""
        isEditingKey = false
        keyCheck = .idle
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        if panel.runModal() == .OK {
            for url in panel.urls { session.addLocalFolder(url) }
        }
    }
}

/// Default audio / subtitle language + quality, seeded onto every title the
/// Detail screen opens (`PlaybackPreferencesStore.applied(to:)`). The user can
/// still override per-title in Detail — these are the starting point. Same store
/// the iOS app uses, so a preference set on either platform carries over.
private struct PlaybackSettings: View {
    @Bindable var prefs: PlaybackPreferencesStore

    var body: some View {
        Form {
            Section("Defaults") {
                Picker("Quality", selection: $prefs.defaultQuality) {
                    ForEach(PlaybackQuality.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("Audio Language", selection: $prefs.defaultAudioLanguage) {
                    Text("Source default").tag(String?.none)
                    ForEach(PlaybackLanguage.common, id: \.code) { lang in
                        Text(lang.displayName).tag(Optional(lang.code))
                    }
                }
                Picker("Subtitle Language", selection: $prefs.defaultSubtitleLanguage) {
                    Text("Source default").tag(String?.none)
                    Text("Off").tag(Optional("off"))
                    ForEach(PlaybackLanguage.common, id: \.code) { lang in
                        Text(lang.displayName).tag(Optional(lang.code))
                    }
                }
            }
            Section {
                Text("Applied to every title you open. You can still change the audio, subtitles, and quality for a single title on its detail screen.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Episodes") {
                Picker("Skip Intro", selection: $prefs.skipIntro) {
                    ForEach(SkipMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("Skip Credits", selection: $prefs.skipCredits) {
                    ForEach(SkipMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Toggle("Auto-Play Next Episode", isOn: $prefs.autoPlayNext)
                Picker("Next Episode Countdown", selection: $prefs.nextEpisodeCountdown) {
                    ForEach(PlaybackPreferencesStore.countdownOptions, id: \.self) { Text("\($0)s").tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Display preferences that actually affect the Mac grids today — the
/// watched-poster treatment (#280) and hide-watched-in-discovery — bound
/// straight to the shared `PlaybackPreferencesStore`, so they match the iOS app.
private struct AppearanceSettings: View {
    @Bindable var prefs: PlaybackPreferencesStore
    @Bindable var appearance: AppearancePreferenceStore

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Appearance", selection: $appearance.preference) {
                    ForEach(AppearancePreference.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Text("System follows your Mac's Light/Dark setting. Light mode is still being polished.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Discovery") {
                Toggle("Hide watched titles in Discover", isOn: $prefs.hideWatchedInDiscovery)
                Text("Recently Added, Recently Released, and Top Rated show what's still ahead. Your Library always shows everything.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Watched Titles") {
                Picker("Dimming", selection: $prefs.watchedDimming) {
                    ForEach(WatchedDimming.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Toggle("Show “WATCHED” label", isOn: $prefs.watchedShowLabel)
                if prefs.watchedShowLabel {
                    LabeledContent("Label opacity") {
                        Slider(value: $prefs.watchedLabelOpacity,
                               in: PlaybackPreferencesStore.minLabelOpacity...1)
                            .frame(width: 180)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AboutSettings: View {
    @State private var cacheBytes: Int = AetherImageCache.shared.diskUsageBytes()

    private static let repoURL = URL(string: "https://github.com/Wenzlik/Aether")!
    private static let websiteURL = URL(string: "https://aetherplayer.com")!

    private var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
    /// Short git commit stamped into the build (AetherGitCommit) — the cross-
    /// platform build identifier shown in About, like iOS. `nil` if unstamped.
    private var commit: String? {
        guard let c = Bundle.main.infoDictionary?["AetherGitCommit"] as? String,
              !c.isEmpty, !c.hasPrefix("dev") else { return nil }
        return c
    }
    /// Prefer the commit (stamped every build) over the local-only CFBundleVersion.
    private var buildIdentifier: String { commit ?? build }

    private static let supportEmail = "support@aetherplayer.com"
    /// Personal address for "Contact the Creator" — reaches the developer directly.
    private static let creatorEmail = "vasek@aetherplayer.com"

    /// A Support row that opens the user's mail client (mailto). `recipient`
    /// defaults to support@ but "Contact the Creator" passes the creator address.
    /// Bug/Diagnostics rows append a short diagnostics block (no account details).
    private func supportButton(_ title: String, systemImage: String, subject: String, includeDiagnostics: Bool, recipient: String = supportEmail) -> some View {
        Button {
            var body = ""
            if includeDiagnostics {
                body = "\n\n—\nAether \(shortVersion) (\(buildIdentifier))\n\(Self.deviceModel()) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
            }
            var c = URLComponents()
            c.scheme = "mailto"
            c.path = recipient
            c.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
            if let url = c.url { NSWorkspace.shared.open(url) }
        } label: {
            Label(title, systemImage: systemImage)
        }
    }

    private static func deviceModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "Mac" }
        var chars = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &chars, &size, nil, 0)
        // Decode up to the NUL terminator (String(cString:) is deprecated).
        let bytes = chars.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    var body: some View {
        Form {
            Section {
                Image("AetherBrandMark")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 64)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            }
            Section("Version") {
                LabeledContent("Version", value: shortVersion)
                LabeledContent("Build", value: buildIdentifier)
                LabeledContent("Platform", value: "macOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)")
            }
            Section("Storage") {
                LabeledContent("Image Cache", value: DetailFormatting.fileSize(Int64(cacheBytes)))
                Button("Clear Image Cache") {
                    AetherImageCache.shared.clear()
                    cacheBytes = AetherImageCache.shared.diskUsageBytes()
                }
            }
            Section("Support") {
                supportButton("Report a Bug", systemImage: "ladybug.fill",
                              subject: "Aether (macOS) — Bug Report", includeDiagnostics: true)
                supportButton("Feature Request", systemImage: "lightbulb.fill",
                              subject: "Aether (macOS) — Feature Request", includeDiagnostics: false)
                supportButton("Send Diagnostics", systemImage: "stethoscope",
                              subject: "Aether (macOS) — Diagnostics", includeDiagnostics: true)
                supportButton("Contact the Creator", systemImage: "envelope.fill",
                              subject: "Aether (macOS)", includeDiagnostics: false,
                              recipient: Self.creatorEmail)
            }
            Section("Links") {
                Link(destination: Self.websiteURL) { Label("Website", systemImage: "globe") }
                Link(destination: Self.repoURL) { Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right") }
            }
            Section {
                Text("Plays media with mpv (libmpv), FFmpeg, and libass — © their respective authors, under GPL/LGPL.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
    }
}
