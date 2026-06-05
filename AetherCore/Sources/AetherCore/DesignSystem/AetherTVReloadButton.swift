import SwiftUI

/// A focusable "Reload" button — tvOS's stand-in for pull-to-refresh, which the
/// platform doesn't offer. Placed at the top of Home / Library / Discover so a
/// remote user can manually re-fetch. (Defined cross-platform so it compiles
/// everywhere; only used inside `#if os(tvOS)`.)
public struct AetherTVReloadButton: View {
    private let action: () -> Void

    public init(action: @escaping () -> Void) {
        self.action = action
    }

    public var body: some View {
        AetherButton("Reload", systemImage: "arrow.clockwise", role: .secondary, action: action)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}
