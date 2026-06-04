#if os(visionOS)
import SwiftUI
import RealityKit
import UIKit
import AVFoundation
import Combine
import os
import AetherCore

/// The Dark Theater immersive **environment** — and only the environment.
///
/// It draws a near-black space with a subtle Aether-violet accent glow. It does
/// **not** render the movie: the system docks the native `AVPlayerViewController`
/// into this space automatically once it's open (see
/// `docs/next-steps/visionos-cinema.md` → Part 1/2). Keeping video out of here
/// is the whole point — the system owns rendering, sizing, and controls.
///
/// Full immersion gives real OLED black (a screening room, not passthrough). The
/// procedural content is intentionally minimal — no particles, no shaders, no
/// animated effects — so it's cheap and reliable. A richer authored environment
/// with a custom `DockingRegion` and floor reflections is Phase 2.
struct DarkTheaterView: View {
    /// Cinema state — so the theater can reset it when playback ends.
    let cinema: CinemaManager
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    private static let log = Logger(subsystem: "cz.zmrhal.aether", category: "cinema")

    var body: some View {
        RealityView { content in
            content.add(Self.makeEnvironment())
        }
        .onAppear { Self.log.notice("DarkTheater appeared (space open)") }
        .onDisappear { Self.log.notice("DarkTheater disappeared (space closed)") }
        // Authoritative exit: this view lives for as long as the immersive space
        // is open (it *is* the space's scene), so its end-of-playback observer
        // fires reliably even when the docked player detaches the window's view
        // tree. When the movie ends, close the space and reset cinema state;
        // `DetailView` reacts to `cinema` going idle by dropping the player.
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { _ in
            Self.log.notice("DarkTheater: didPlayToEnd → dismiss space + cinema.end()")
            Task { @MainActor in
                await dismissImmersiveSpace()
                cinema.end()
            }
        }
    }

    /// Build the procedural Dark Theater: a dark floor for grounding plus two
    /// dim violet accent lights. `@MainActor` because RealityKit entity /
    /// component initialisers are main-actor-isolated.
    @MainActor
    private static func makeEnvironment() -> Entity {
        let root = Entity()
        root.name = "DarkTheater"

        // A large, near-black floor so the space reads as a room with a ground,
        // and so the docked screen's glow has somewhere to fall.
        var floorMaterial = PhysicallyBasedMaterial()
        floorMaterial.baseColor = .init(tint: color(0x0E0E11))
        floorMaterial.roughness = .init(floatLiteral: 0.55)
        floorMaterial.metallic = .init(floatLiteral: 0.0)
        let floor = ModelEntity(
            mesh: .generatePlane(width: 60, depth: 60),
            materials: [floorMaterial]
        )
        floor.name = "Floor"
        root.addChild(floor)

        // Restrained violet accent — two low, dim point lights either side,
        // toward the front where the screen docks. Calm, not neon.
        root.addChild(makeAccentLight(name: "AccentLightL", at: [-5, 1.0, -3.5]))
        root.addChild(makeAccentLight(name: "AccentLightR", at: [5, 1.0, -3.5]))

        return root
    }

    @MainActor
    private static func makeAccentLight(name: String, at position: SIMD3<Float>) -> Entity {
        let entity = Entity()
        entity.name = name
        entity.components.set(
            PointLightComponent(
                color: color(0x8B5CF6),   // Aether Violet
                intensity: 1800,
                attenuationRadius: 14
            )
        )
        entity.position = position
        return entity
    }

    /// `UIColor` from a 24-bit RGB hex literal — RealityKit takes `UIColor`,
    /// not SwiftUI `Color`.
    private static func color(_ hex: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}
#endif
