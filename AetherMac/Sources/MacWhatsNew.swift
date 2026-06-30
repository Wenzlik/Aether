import SwiftUI
import AetherCore

/// One past release, shown in the macOS **What's New** list. Mirrors the iOS
/// `ReleaseNote` shape. The data is intentionally duplicated from the iOS app
/// target's `SettingsViewModel.releaseHistory`: `ReleaseNote`/`releaseHistory`
/// live in the iOS target (not `AetherCore`), and `AetherCore` has no String
/// Catalog, so there is no shared home for these *localized* marketing lines
/// today. Keeping a macOS mirror is the low-risk path; promoting both platforms
/// to a single source of truth in `AetherCore` (with its own catalog) is the
/// eventual cleanup. Keep this list in lockstep with the iOS one.
struct MacReleaseNote: Identifiable, Sendable {
    var id: String { version }
    let version: String
    let codename: String?
    /// Short "what's new" lines for a detailed (recent) build. Empty for a
    /// grouped major-release entry.
    var new: [LocalizedStringResource] = []
    /// Short "what was fixed" lines for a detailed (recent) build.
    var fixed: [LocalizedStringResource] = []
    /// One-line overview for a grouped major release (pre-0.8). `nil` for a
    /// detailed build (which uses `new` / `fixed` instead).
    var summary: LocalizedStringResource? = nil
}

/// Codename for the current release, surfaced in the What's New header. Theme:
/// constellations, alphabetical (see AGENTS.md → Release process). Bump this
/// alongside `MARKETING_VERSION`.
let macReleaseCodename = "Eridanus"

/// Release notes, newest first — the macOS mirror of the iOS `releaseHistory`.
/// Recent builds are detailed (`new` / `fixed`); pre-0.8 releases are grouped
/// under their major version with a one-line `summary`. Platform-prefixed lines
/// ("All:" / "macOS:" / "iOS:" / "visionOS:") match the iOS list verbatim.
let macReleaseHistory: [MacReleaseNote] = [
    MacReleaseNote(version: "0.8.7", codename: "Eridanus",
                   new: [
                       "All: Ask Aether explains its picks in your language.",
                       "All: New recommendation controls in Settings.",
                       "All: Discover keeps your picks steady, refreshing them once a day.",
                       "macOS: Ask Aether now works from the Library, too.",
                   ],
                   fixed: [
                       "All: The Discover banner no longer scrolls on its own — swipe to browse.",
                       "macOS: Discover no longer reshuffles its rows every second.",
                       "macOS: A more compact Discover banner.",
                       "All: Loading screens show a clear indicator instead of a skeleton.",
                   ]),
    MacReleaseNote(version: "0.8.6", codename: "Eridanus",
                   new: [
                       "Ask Aether — find something to watch in plain language.",
                       "It only suggests titles you already own.",
                       "On-device with Apple Intelligence where available.",
                       "macOS: Open and play local files right in the window.",
                       "macOS: A Local section remembers recents and where you left off.",
                   ],
                   fixed: [
                       "visionOS: Cinema only offers formats it can play.",
                       "visionOS: Technical Details can now be closed.",
                       "iOS: Close buttons work across the Settings panels.",
                       "All: Downloaded titles now play offline.",
                       "All: Adding a second Plex account works.",
                       "All: Clearer message when a title can't be played yet.",
                       "All: The Library loading screen no longer looks stuck.",
                   ]),
    MacReleaseNote(version: "0.8.5", codename: "Eridanus",
                   new: [
                       "Connect several servers into one library.",
                       "Identify mis-matched Jellyfin titles from Detail.",
                       "Sign in to Jellyfin with username and password.",
                       "A bolder, full-width Discover banner.",
                       "Auto-Play Next rolls over between seasons.",
                   ],
                   fixed: [
                       "Resuming a transcoded Jellyfin title works again.",
                       "The library no longer flashes empty on refresh.",
                       "Dark title logos fall back to readable text.",
                       "Settings no longer hides under the iPad tab bar.",
                       "Auto-Play Next keeps your audio and subtitle language.",
                       "Auto-Play Next and player prompts now work on tvOS.",
                   ]),
    MacReleaseNote(version: "0.8.4", codename: "Eridanus",
                   new: [
                       "Plex Home profiles — pick who's watching.",
                       "Personal star ratings, synced to Plex.",
                       "German, French and Spanish.",
                       "Native playback of downloaded Dolby Digital.",
                   ],
                   fixed: [
                       "Your preferred audio and subtitle language now applies.",
                   ]),
    MacReleaseNote(version: "0.8.3", codename: "Eridanus",
                   new: [
                       "Downloaded MKVs play through AVPlayer, with seeking.",
                       "SMB: match a title to TMDb, confirm-first.",
                       "SMB: smarter TV show detection.",
                   ],
                   fixed: [
                       "Fixed a playback crash on local and SMB files.",
                       "Player controls now auto-hide during playback.",
                       "A calmer Library loading screen.",
                   ]),
    MacReleaseNote(version: "0.7", codename: "Draco",
                   summary: "A native Mac app, native SMB, multiple servers in one library, and a broad UX polish pass."),
    MacReleaseNote(version: "0.6", codename: "Cassiopeia",
                   summary: "The on-device Local Library, an Infuse-style Detail screen, a cinematic UI refresh, and a tvOS polish pass."),
    MacReleaseNote(version: "0.5", codename: "Boötes",
                   summary: "Cinema Mode on Apple Vision Pro — a dark, immersive screening room."),
    MacReleaseNote(version: "0.4", codename: "Andromeda",
                   summary: "The Unified Library — Plex and Jellyfin titles merged into one collection."),
    MacReleaseNote(version: "0.3", codename: nil,
                   summary: "Offline downloads with background transfers and resume."),
]

/// The macOS **What's New** sheet, opened from About. A headline with the
/// current version + codename, the current release's New / Fixed lines, then the
/// release history. Native macOS idiom (cards over the standard sheet chrome) —
/// the mac counterpart of the iOS `WhatsNewSheet`.
struct MacWhatsNewView: View {
    /// The running app version — selects which entry is the "current" headline.
    let currentVersion: String
    var history: [MacReleaseNote] = macReleaseHistory
    let codename: String

    @Environment(\.dismiss) private var dismiss

    /// The current release — matched by version, falling back to the newest entry.
    private var current: MacReleaseNote? {
        history.first { $0.version == currentVersion } ?? history.first
    }

    /// Everything below the current release.
    private var pastReleases: [MacReleaseNote] {
        guard let current else { return history }
        return history.filter { $0.id != current.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("What's New")
                    .font(.largeTitle.weight(.bold))
                if let current {
                    Text("Version \(current.version) · “\(current.codename ?? codename)”")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let current {
                        card { releaseBody(current) }
                    }
                    if !pastReleases.isEmpty {
                        Text("RELEASE HISTORY")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .tracking(0.6)
                            .padding(.horizontal, 24)
                            .padding(.top, 6)
                        ForEach(pastReleases) { release in
                            card { releaseBody(release) }
                        }
                    }
                }
                .padding(.bottom, 16)
            }

            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560, height: 620)
        .tint(AetherMacTheme.accent)
    }

    /// A release row: codename header (for history rows), then its one-line
    /// summary (grouped major release) or its New / Fixed lines (detailed build).
    @ViewBuilder
    private func releaseBody(_ release: MacReleaseNote) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(release.codename.map { "\(release.version) · \($0)" } ?? release.version)
                .font(.headline)
            if let summary = release.summary {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                changeGroup("New", symbol: "checkmark.circle.fill",
                            tint: .green, items: release.new)
                changeGroup("Fixed", symbol: "wrench.adjustable.fill",
                            tint: AetherMacTheme.accent, items: release.fixed)
            }
        }
    }

    /// A labelled list of change lines (New or Fixed). Renders nothing when empty.
    @ViewBuilder
    private func changeGroup(_ title: LocalizedStringKey, symbol: String,
                             tint: Color, items: [LocalizedStringResource]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .tracking(0.6)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: symbol)
                            .font(.caption)
                            .foregroundStyle(tint)
                        Text(item)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    /// The shared card container used for the current release and each history row.
    @ViewBuilder
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.quaternary.opacity(0.5))
            )
            .padding(.horizontal, 24)
    }
}
