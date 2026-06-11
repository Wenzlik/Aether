import SwiftUI
import AetherCore

/// The dedicated **About Aether** screen — brand wordmark, tagline, author, and
/// optional links. Clean and premium. Tapping the wordmark seven times unlocks
/// the hidden Developer Mode (see `developer.unlocked`).
///
/// NOTE: confirm the public link URLs before shipping to TestFlight.
struct AboutView: View {
    let versionLabel: String
    let onClose: () -> Void

    @AppStorage("developer.unlocked") private var developerUnlocked = false
    @State private var tapCount = 0
    @State private var justUnlocked = false
    #if !os(tvOS)
    @Environment(\.openURL) private var openURL
    #endif

    private let githubURL = URL(string: "https://github.com/Wenzlik/Aether")
    private let websiteURL = URL(string: "https://aetherplayer.com")
    private let roadmapURL = URL(string: "https://github.com/Wenzlik/Aether/blob/main/ROADMAP.md")

    private static let unlockTapTarget = 7

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
                hero
                authorSection
                #if !os(tvOS)
                linksSection
                #endif
                footer
            }
            .padding(AetherDesign.Spacing.l)
            .frame(maxWidth: AetherSheetLayout.maxContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            .tvOSScrollFocusable()
        }
        .aetherScreenBackground()
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(AetherDesign.Palette.textTertiary)
                    .padding(AetherDesign.Spacing.m)
            }
            .buttonStyle(.plain)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            AetherWordmark(.large)
                .contentShape(Rectangle())
                .onTapGesture { registerLogoTap() }
            Text("Personal media, beautifully played.")
                .font(AetherDesign.Typography.cardTitle)
                .foregroundStyle(AetherDesign.Palette.textSecondary)
            Text("Aether is a native player for your own media — Plex, Jellyfin, and files on your device — built for Apple platforms with one cinematic interface across iPhone, iPad, Apple TV, and Vision Pro. No catalogue to rent, no account to sell: just your library, played well.")
                .font(AetherDesign.Typography.body)
                .foregroundStyle(AetherDesign.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var authorSection: some View {
        AetherSettingsSection("Created By") {
            AetherSettingsRow(label: "Vaclav Zmrhal", systemImage: "person.crop.circle.fill", value: nil)
            AetherSettingsRow(label: "Yana Shamruk", systemImage: "person.crop.circle.fill", value: nil)
        }
    }

    #if !os(tvOS)
    private var linksSection: some View {
        AetherSettingsSection("Links") {
            if let githubURL {
                AetherSettingsRow(label: "GitHub", systemImage: "chevron.left.forwardslash.chevron.right", value: nil) {
                    openURL(githubURL)
                }
            }
            if let websiteURL {
                AetherSettingsRow(label: "Website", systemImage: "globe", value: nil) {
                    openURL(websiteURL)
                }
            }
            if let roadmapURL {
                AetherSettingsRow(label: "Roadmap", systemImage: "map.fill", value: nil) {
                    openURL(roadmapURL)
                }
            }
        }
    }
    #endif

    private var footer: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
            Text(versionLabel)
                .font(AetherDesign.Typography.metadata)
                .foregroundStyle(AetherDesign.Palette.textTertiary)
            // Attribution for the bundled VLCKit engine (local mkv playback).
            Text("Plays non-native formats with VLCKit © VideoLAN, licensed under LGPL-2.1.")
                .font(AetherDesign.Typography.caption)
                .foregroundStyle(AetherDesign.Palette.textTertiary)
            if developerUnlocked {
                Label(justUnlocked ? "Developer Mode unlocked" : "Developer Mode enabled", systemImage: "hammer.fill")
                    .font(AetherDesign.Typography.caption)
                    .foregroundStyle(AetherDesign.Palette.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func registerLogoTap() {
        guard !developerUnlocked else { return }
        tapCount += 1
        if tapCount >= Self.unlockTapTarget {
            developerUnlocked = true
            justUnlocked = true
        }
    }
}
