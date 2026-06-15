import SwiftUI
import AetherCore

// `AetherLoadingDots` now lives in AetherCore's design system (shared with the
// macOS app); see `AetherCore/DesignSystem/AetherLoadingDots.swift`.

/// Wraps a state view (loading / empty / error) so it (1) fills the screen and
/// centers, and (2) lives inside a bouncing `ScrollView` — so the screen's
/// `.refreshable` works even when there's no content yet. Without this the
/// states render content-sized (the gradient shows as a band) and aren't
/// scrollable (pull-to-refresh can't reach them, so an empty state gets stuck).
struct AetherCenteredScrollState<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                content()
                    .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .center)
            }
            #if !os(tvOS)
            // Always bounce so pull-to-refresh fires even when the content fits.
            .scrollBounceBehavior(.always)
            #endif
        }
    }
}

/// Layout constants for the full-screen info sheets (About / Diagnostics /
/// What's New). Wider on tvOS so they use the available space instead of a
/// phone-width column centred on a 16:9 screen.
enum AetherSheetLayout {
    static var maxContentWidth: CGFloat {
        #if os(tvOS)
        return 1320
        #else
        return 680
        #endif
    }
}

extension View {
    /// tvOS: make otherwise-unfocusable scroll content focusable so the Siri
    /// Remote can scroll it (a ScrollView of plain text has no focus target and
    /// can't be scrolled). No-op on every other platform.
    @ViewBuilder
    func tvOSScrollFocusable() -> some View {
        #if os(tvOS)
        self.focusable()
        #else
        self
        #endif
    }
}
