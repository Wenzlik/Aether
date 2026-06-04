import SwiftUI

/// Inline search field used at the top of Home and Library, **replacing**
/// the system `.searchable` modifier on those screens.
///
/// The system modifier insists on placing the search bar at the very top of
/// the surface (above any scroll content), which conflicts with the brand
/// brief that the Aether wordmark is the first thing the user sees when
/// they open the app. This component lets us own the position — the
/// wordmark goes at the top, this field sits beneath it, the rails follow.
///
/// Visual: the capsule + magnifying-glass + placeholder pattern Apple uses
/// for the iOS 26 search field, but as a regular `View` we can stack inside
/// a `LazyVStack`. Binds to the same `@State searchQuery` the screens
/// already use — switching from `.searchable` is a 1:1 binding swap, the
/// screens' "is the user searching" computed property keeps working.
public struct AetherSearchField: View {
    @Binding public var text: String
    public let prompt: String

    public init(text: Binding<String>, prompt: String) {
        self._text = text
        self.prompt = prompt
    }

    public var body: some View {
        HStack(spacing: AetherDesign.Spacing.s) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AetherDesign.Palette.textTertiary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .foregroundStyle(AetherDesign.Palette.textPrimary)
                .submitLabel(.search)
                .autocorrectionDisabled()
            #if os(iOS) || os(visionOS)
                .textInputAutocapitalization(.never)
            #endif
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AetherDesign.Palette.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, AetherDesign.Spacing.m)
        .padding(.vertical, AetherDesign.Spacing.s)
        .background(
            Capsule()
                .fill(AetherDesign.Palette.surface)
        )
    }
}

