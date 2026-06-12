import SwiftUI

/// A designed empty state — calm hero glyph, a clear title, a one-sentence
/// body, and at most one CTA.
///
/// Used by Home (no source, no servers, empty library), Detail (no children
/// yet), Settings (not signed in), and any future screen that would otherwise
/// stub a generic "No items."
public struct AetherEmptyState: View {
    public let glyph: String
    public let title: String
    public let message: String
    public let action: Action?

    public init(
        glyph: String,
        title: String,
        message: String,
        action: Action? = nil
    ) {
        self.glyph = glyph
        self.title = title
        self.message = message
        self.action = action
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.m) {
            Image(systemName: glyph)
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(AetherDesign.Palette.textTertiary)
                .padding(.bottom, AetherDesign.Spacing.s)

            Text(LocalizedStringKey(title))
                .font(AetherDesign.Typography.sectionTitle)
                .foregroundStyle(AetherDesign.Palette.textPrimary)

            Text(LocalizedStringKey(message))
                .font(AetherDesign.Typography.body)
                .foregroundStyle(AetherDesign.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let action {
                AetherButton(action.label, role: .primary, action: action.run)
                    .padding(.top, AetherDesign.Spacing.s)
            }
        }
        .padding(.horizontal, AetherDesign.Spacing.l)
        .padding(.top, AetherDesign.Spacing.xxl)
        .frame(maxWidth: 520, alignment: .leading)
        #if os(tvOS)
        // On tvOS a pushed screen with NOTHING focusable is a trap: the Menu
        // button exits the app instead of popping the navigation, so an empty
        // Collections / Actors view leaves the user stuck (force-quit only).
        // Make the empty state itself focusable (only when there's no CTA to
        // focus) so Menu pops back to the Library (#311).
        .focusable(action == nil)
        #endif
    }

    public struct Action {
        public let label: String
        public let run: () -> Void

        public init(label: String, run: @escaping () -> Void) {
            self.label = label
            self.run = run
        }
    }
}

#if DEBUG
struct AetherEmptyState_Previews: PreviewProvider {
    static var previews: some View {
        AetherEmptyState(
            glyph: "film.stack",
            title: "Your library is empty",
            message: "Connect a Plex or Synology source to start watching.",
            action: .init(label: "Add a source") {}
        )
        .padding(AetherDesign.Spacing.l)
        .background(AetherDesign.Palette.background)
        .previewLayout(.sizeThatFits)
    }
}
#endif
