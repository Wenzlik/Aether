import SwiftUI
import AetherCore

/// The native macOS **Settings** window (⌘, / "Aether ▸ Settings…"), surfaced
/// via the `Settings` scene. Kept honest — only what actually works on the Mac
/// today: connecting / disconnecting sources, and About. Playback preferences
/// follow once they're wired into the Mac playback path.
struct MacSettingsView: View {
    var session: MacSession

    var body: some View {
        TabView {
            AccountsSettings(session: session)
                .tabItem { Label("Accounts", systemImage: "person.2") }
            PlaybackSettings(prefs: session.playbackPrefs)
                .tabItem { Label("Playback", systemImage: "play.rectangle") }
            AppearanceSettings(prefs: session.playbackPrefs)
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 360)
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
                    LabeledContent("Status", value: "Connected")
                    Button("Sign Out of Plex", role: .destructive) {
                        Task { await session.signOutPlex() }
                    }
                } else {
                    LabeledContent("Status", value: "Not connected")
                    Button("Connect Plex…") { signIn = .plex }
                }
            }
            Section("Jellyfin") {
                if session.isJellyfinConnected {
                    LabeledContent("Status", value: "Connected")
                    Button("Sign Out of Jellyfin", role: .destructive) {
                        Task { await session.signOutJellyfin() }
                    }
                } else {
                    LabeledContent("Status", value: "Not connected")
                    Button("Connect Jellyfin…") { signIn = .jellyfin }
                }
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
    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (\(b))"
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tint)
            Text("Aether").font(.title.bold())
            Text("Version \(version)").foregroundStyle(.secondary)
            Text("Personal media, beautifully played.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Plays non-native formats with VLCKit © VideoLAN, licensed under LGPL-2.1.")
                .font(.caption).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
