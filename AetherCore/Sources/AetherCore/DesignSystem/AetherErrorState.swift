import SwiftUI

/// A designed error state — same shape as `AetherEmptyState`, but with a
/// warning glyph and a retry action that's mandatory, not optional.
///
/// Used by Home (couldn't reach the server), Detail (children failed to load),
/// Player (playback unavailable), and discovery (couldn't reach Plex).
public struct AetherErrorState: View {
    public let glyph: String
    public let title: String
    public let message: String
    public let retry: Retry?

    public init(
        glyph: String = "wifi.exclamationmark",
        title: String,
        message: String,
        retry: Retry? = nil
    ) {
        self.glyph = glyph
        self.title = title
        self.message = message
        self.retry = retry
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: AetherDesign.Spacing.s) {
            Image(systemName: glyph)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(AetherDesign.Palette.textTertiary)
                .padding(.bottom, AetherDesign.Spacing.xs)

            Text(title)
                .font(AetherDesign.Typography.sectionTitle)
                .foregroundStyle(AetherDesign.Palette.textPrimary)

            Text(message)
                .font(AetherDesign.Typography.body)
                .foregroundStyle(AetherDesign.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let retry {
                AetherButton(retry.label, role: .primary, action: retry.run)
                    .padding(.top, AetherDesign.Spacing.s)
            }
        }
        .padding(.horizontal, AetherDesign.Spacing.l)
        .padding(.top, AetherDesign.Spacing.xxl)
        .frame(maxWidth: 520, alignment: .leading)
    }

    public struct Retry {
        public let label: String
        public let run: () -> Void

        public init(label: String = "Try again", run: @escaping () -> Void) {
            self.label = label
            self.run = run
        }
    }
}

#if DEBUG
struct AetherErrorState_Previews: PreviewProvider {
    static var previews: some View {
        AetherErrorState(
            title: "Couldn't reach your server",
            message: "Your Plex server didn't answer in time. Check that it's online and try again.",
            retry: .init {}
        )
        .padding(AetherDesign.Spacing.l)
        .background(AetherDesign.Palette.background)
        .previewLayout(.sizeThatFits)
    }
}
#endif
