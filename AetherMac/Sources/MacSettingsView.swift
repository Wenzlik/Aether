import SwiftUI
import AetherCore

/// The native macOS **Settings** window (⌘, / "Aether ▸ Settings…"), surfaced
/// via the `Settings` scene: Accounts, Playback defaults, Appearance (watched
/// display), and About. All bound to the same stores the iOS app uses, so a
/// preference set on either platform carries over.
struct MacSettingsView: View {
    var session: MacSession

    var body: some View {
        TabView {
            GeneralSettings(session: session)
                .tabItem { Label("General", systemImage: "gearshape") }
            AccountsSettings(session: session)
                .tabItem { Label("Accounts", systemImage: "person.2") }
            PlaybackSettings(prefs: session.playbackPrefs)
                .tabItem { Label("Playback", systemImage: "play.rectangle") }
            AppearanceSettings(prefs: session.playbackPrefs)
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 380)
        .tint(AetherMacTheme.accent)
        .preferredColorScheme(.dark)
        .environment(\.locale, session.appLocale)
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
                LabeledContent("Local Library", value: "Coming soon")
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
                Button("Add Folder…", systemImage: "plus") { addFolder() }
                Text("Pick folders on this Mac or a mounted network share. Aether scans them for movies and shows and adds them to your library.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Metadata") {
                SecureField("TMDb API Key", text: $session.tmdbToken)
                LabeledContent("Status", value: session.isTMDBConfigured ? "Configured" : "Not set")
                Text("Used to fetch posters and descriptions for your local library. Leave blank to use the key built into the app, or paste your own from themoviedb.org.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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

    var body: some View {
        Form {
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

    private var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "play.rectangle.on.rectangle")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Aether").font(.title2.bold())
                        Text("Personal media, beautifully played.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Version") {
                LabeledContent("Version", value: shortVersion)
                LabeledContent("Build", value: build)
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
                Link("Report a Bug", destination: Self.repoURL.appendingPathComponent("issues/new"))
                Link("Feature Request", destination: Self.repoURL.appendingPathComponent("issues/new"))
                Link("Source on GitHub", destination: Self.repoURL)
            }
            Section {
                Text("Plays media with mpv (libmpv), FFmpeg, and libass — © their respective authors, under GPL/LGPL.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
    }
}
