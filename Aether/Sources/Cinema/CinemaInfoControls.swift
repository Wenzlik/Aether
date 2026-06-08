#if os(visionOS)
import SwiftUI
import AetherCore

/// The in-cinema **Screen Size** + **Seat** controls, designed to be hosted as a
/// tab in the native `AVPlayerViewController` *Info panel* (via
/// `customInfoViewControllers`), the way Apple's own Destination Video sample
/// surfaces custom controls.
///
/// **Why the Info panel and not `contextualActions`:** `contextualActions` is
/// documented to render *only while the transport bar is hidden* and is built
/// for transient single prompts (e.g. "Skip Intro") — so it vanished the moment
/// the user tapped to reveal the native controls, and degraded with more than
/// one action. `customInfoViewControllers` renders as a persistent tab that is
/// reached by tapping the video, has no item limit, is system-composited (always
/// in front of the docked screen), and rides along when the controls detach in
/// the docked/expanded experience. `transportBarCustomMenuItems` (inline buttons
/// next to the scrubber) is tvOS-only and unavailable on visionOS, so the Info
/// panel is the supported placement. See `SystemVideoPlayer`.
///
/// Selecting a value calls `CinemaManager`, which `DarkTheaterView` observes to
/// resize the docked screen / slide the room (and re-dock to re-fit). Because
/// `CinemaManager` is `@Observable`, the highlighted selection updates live even
/// though the hosting controller is built once.
struct CinemaInfoControls: View {
    let cinema: CinemaManager

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            row("Screen Size") {
                ForEach(CinemaScreenPreset.ordered, id: \.self) { preset in
                    chip(preset.displayName, selected: cinema.screenPreset == preset) {
                        cinema.setScreenPreset(preset)
                    }
                }
            }
            row("Seat") {
                ForEach(CinemaSeat.ordered, id: \.self) { seat in
                    chip(seat.displayName, selected: cinema.seat == seat) {
                        cinema.setSeat(seat)
                    }
                }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func row(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 12) { content() }
        }
    }

    private func chip(_ title: String, selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .tint(selected ? AetherDesign.Palette.accent : Color.secondary.opacity(0.35))
    }
}
#endif
