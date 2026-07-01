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
    // Dismiss the presentation directly. Binding-based dismissal (the parent
    // setting its `infoSheet`/`supportSheet` state to nil via `onClose`) is
    // unreliable on iOS when several `.sheet` modifiers are stacked on one view
    // (as in SettingsView) — the close button looked dead. `dismiss()` always
    // closes the current sheet; `onClose()` is kept for any parent-side cleanup.
    @Environment(\.dismiss) private var dismiss
    #if !os(tvOS)
    @Environment(\.openURL) private var openURL
    #endif

    private let websiteURL = URL(string: "https://aetherplayer.com")

    private static let unlockTapTarget = 7

    var body: some View {
        #if os(tvOS)
        tvBody
        #else
        defaultBody
        #endif
    }

    // MARK: - tvOS layout

    #if os(tvOS)
    /// Full-screen centered layout for the 10-foot UI. No floating X button —
    /// the remote's Back/Menu dismisses. Large wordmark, generous breathing room.
    private var tvBody: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(spacing: 0) {
                    // Wordmark — large, centered, tappable for dev mode
                    AetherWordmark(.large)
                        .contentShape(Rectangle())
                        .onTapGesture { registerLogoTap() }
                        .padding(.bottom, AetherDesign.Spacing.l)

                    // Tagline
                    Text("Personal media, beautifully played.")
                        .font(.system(size: 34, weight: .medium, design: .default))
                        .foregroundStyle(AetherDesign.Palette.textPrimary)
                        .multilineTextAlignment(.center)
                        .padding(.bottom, AetherDesign.Spacing.m)

                    // Description
                    Text("Aether is a native player for your own media — Plex, Jellyfin, and files on your device — built for Apple platforms with one cinematic interface across iPhone, iPad, Apple TV, and Vision Pro. No catalogue to rent, no account to sell: just your library, played well.")
                        .font(.system(size: 26, weight: .regular))
                        .foregroundStyle(AetherDesign.Palette.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 900)
                        .padding(.bottom, AetherDesign.Spacing.xxl)

                    // Credits — horizontal pill layout
                    HStack(spacing: AetherDesign.Spacing.xl) {
                        tvCreditPill(
                            name: "Vaclav Zmrhal",
                            role: "Creator",
                            icon: "person.crop.circle.fill"
                        )
                        tvCreditPill(
                            name: "Yana Shamruk",
                            role: "Ideas",
                            icon: "sparkles"
                        )
                    }
                    .padding(.bottom, AetherDesign.Spacing.xxl)

                    // Version + attribution
                    VStack(spacing: AetherDesign.Spacing.xs) {
                        Text(versionLabel)
                            .font(.system(size: 22, weight: .regular))
                            .foregroundStyle(AetherDesign.Palette.textTertiary)
                        Text("Plays non-native formats with VLCKit © VideoLAN, licensed under LGPL-2.1.")
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(AetherDesign.Palette.textTertiary)
                            .multilineTextAlignment(.center)
                        if developerUnlocked {
                            Label(
                                justUnlocked ? "Developer Mode unlocked" : "Developer Mode enabled",
                                systemImage: "hammer.fill"
                            )
                            .font(.system(size: 20))
                            .foregroundStyle(AetherDesign.Palette.accent)
                        }
                    }
                    .padding(.bottom, AetherDesign.Spacing.xxl)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 80)
                .padding(.horizontal, 120)
            }
        }
        .aetherScreenBackground()
        .onExitCommand(perform: onClose)
    }

    private func tvCreditPill(name: String, role: LocalizedStringKey, icon: String) -> some View {
        VStack(spacing: AetherDesign.Spacing.s) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(AetherDesign.Palette.accent)
            Text(name)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(AetherDesign.Palette.textPrimary)
            Text(role)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(AetherDesign.Palette.textSecondary)
        }
        .frame(minWidth: 300)
        .padding(AetherDesign.Spacing.xl)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
    #endif

    // MARK: - iOS / visionOS layout

    #if !os(tvOS)
    private var defaultBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AetherDesign.Spacing.xl) {
                hero
                authorSection
                linksSection
                footer
            }
            .padding(AetherDesign.Spacing.l)
            .frame(maxWidth: AetherSheetLayout.maxContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .aetherScreenBackground()
        .overlay(alignment: .topTrailing) {
            Button { dismiss(); onClose() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(AetherDesign.Palette.textTertiary)
                    .padding(AetherDesign.Spacing.m)
                    // Bigger tap target: `.plain` button hit-tests only the glyph
                    // without this — the X looked tiny / hard to hit (≥44pt HIG).
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
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
        AetherSettingsSection("Credits") {
            AetherSettingsRow(label: "Vaclav Zmrhal", systemImage: "person.crop.circle.fill", value: "Creator")
            AetherSettingsRow(label: "Yana Shamruk", systemImage: "sparkles", value: "Ideas")
        }
    }

    private var linksSection: some View {
        AetherSettingsSection("Links") {
            if let websiteURL {
                AetherSettingsRow(label: "Website", systemImage: "globe", value: nil) {
                    openURL(websiteURL)
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.xs) {
            Text(versionLabel)
                .font(AetherDesign.Typography.metadata)
                .foregroundStyle(AetherDesign.Palette.textTertiary)
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
    #endif

    private func registerLogoTap() {
        guard !developerUnlocked else { return }
        tapCount += 1
        if tapCount >= Self.unlockTapTarget {
            developerUnlocked = true
            justUnlocked = true
        }
    }
}
