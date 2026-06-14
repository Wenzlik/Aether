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
    /// `LocalizedStringKey` (not `String`) so the placeholder actually localizes
    /// — `TextField(_ titleKey:…)` localizes a key; the `String` overload would
    /// render verbatim (#320). Call sites pass literals ("Search your library",
    /// "Filter \(title)"), which become catalog keys.
    public let prompt: LocalizedStringKey
    /// Optional focus binding owned by the host (`@FocusState`). When provided,
    /// the field becomes programmatically focus-controllable so the host can
    /// dismiss the keyboard (tap-outside / scroll / select-result), and pressing
    /// Search/Done resigns focus here. Pass `nil` to keep the old behaviour.
    private let focusBinding: FocusState<Bool>.Binding?

    public init(
        text: Binding<String>,
        prompt: LocalizedStringKey,
        focus: FocusState<Bool>.Binding? = nil
    ) {
        self._text = text
        self.prompt = prompt
        self.focusBinding = focus
    }

    public var body: some View {
        HStack(spacing: AetherDesign.Spacing.s) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AetherDesign.Palette.textTertiary)
            field
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

    /// The text field, with the host's focus binding applied when present.
    /// Pressing Search/Done resigns focus so the keyboard dismisses.
    @ViewBuilder
    private var field: some View {
        let base = TextField(prompt, text: $text)
            .textFieldStyle(.plain)
            .foregroundStyle(AetherDesign.Palette.textPrimary)
            .submitLabel(.search)
            .autocorrectionDisabled()
        #if os(iOS) || os(visionOS)
            .textInputAutocapitalization(.never)
        #endif

        if let focusBinding {
            base
                .focused(focusBinding)
                .onSubmit { focusBinding.wrappedValue = false }
        } else {
            base
        }
    }
}

