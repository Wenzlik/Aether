#if os(visionOS)
import RealityKit
import UIKit
import AetherCore

/// Builds the procedural Dark Theater — Aether's signature cinematic space
/// (see `docs/next-steps/visionos-cinema.md` → *Initial Environment*).
///
/// Deliberately minimal: a near-black floor, a dark back wall the screen sits
/// against, soft indirect lighting, and one restrained violet accent line.
/// **No particles, no nebulae, no sci-fi panels** — the movie is the hero, the
/// room only supports it (spec §Design Principle 2). Fully procedural (no USDZ
/// assets) so it's fast to iterate; if it doesn't read premium on device it
/// graduates to a baked environment later.
///
/// All numeric values here (intensities, sizes, tints) are a first pass meant
/// to be tuned on real hardware — the simulator hides how light actually reads
/// in the Vision Pro (AGENTS.md → tvOS/visionOS rules: judge on device).
///
/// `@MainActor`-isolated because RealityKit's `Entity` / `ModelEntity` /
/// component initialisers are main-actor-isolated; the only caller is the
/// `RealityView` make closure, which is already on the main actor.
@MainActor
enum CinemaTheater {

    /// Build the environment root for `environment`. Only `.darkTheater` is
    /// buildable in V1; everything else falls back to it (the picker already
    /// filters on `isAvailable`, so this is just belt-and-braces).
    static func makeEntity(for environment: CinemaEnvironment) -> Entity {
        let root = Entity()
        root.name = "CinemaTheater"
        switch environment {
        case .darkTheater, .nebula, .deepSpace, .orbitStation:
            buildDarkTheater(into: root)
        }
        return root
    }

    // MARK: - Dark Theater

    private static func buildDarkTheater(into root: Entity) {
        root.addChild(makeFloor())
        root.addChild(makeBackWall())
        root.addChild(makeAccentLine())
        for light in makeLighting() {
            root.addChild(light)
        }
    }

    /// A large near-black floor with a touch of sheen, so the screen's glow
    /// pools faintly on it — the "luxury screening room" cue. Slightly above
    /// pure black so the reflection is visible at all.
    private static func makeFloor() -> Entity {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color(0x121214))
        material.roughness = .init(floatLiteral: 0.5)
        material.metallic = .init(floatLiteral: 0.0)

        let floor = ModelEntity(
            mesh: .generatePlane(width: 60, depth: 60),
            materials: [material]
        )
        floor.name = "Floor"
        floor.position = [0, 0, 0]
        return floor
    }

    /// A dark vertical wall behind the screen, so the screen frames against
    /// architecture rather than an infinite void. `generatePlane(width:height:)`
    /// faces +Z toward the viewer.
    private static func makeBackWall() -> Entity {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color(0x0B0B0E))
        material.roughness = .init(floatLiteral: 0.85)
        material.metallic = .init(floatLiteral: 0.0)

        let wall = ModelEntity(
            mesh: .generatePlane(width: 48, height: 24),
            materials: [material]
        )
        wall.name = "BackWall"
        // Behind the screen (screen sits at z = -3), centred vertically so it
        // reads as a tall wall, not a floating panel.
        wall.position = [0, 8, -4.5]
        return wall
    }

    /// The single restrained violet accent: a thin emissive line where the
    /// back wall meets the floor. Unlit so it glows softly regardless of the
    /// room lighting; dim violet, not neon (spec: avoid neon/cyberpunk).
    private static func makeAccentLine() -> Entity {
        let material = UnlitMaterial(color: color(0x3B2A6B))

        let line = ModelEntity(
            mesh: .generatePlane(width: 16, height: 0.05),
            materials: [material]
        )
        line.name = "AccentLine"
        line.position = [0, 0.03, -4.46]
        return line
    }

    // MARK: - Lighting

    /// Soft indirect lighting. One dim, slightly warm directional fill angled
    /// down so the floor and wall are *just* readable, plus two low violet
    /// point lights near the back corners for restrained accent pools. The
    /// video on the screen is the real key light; these only keep the room
    /// from being a flat black void.
    private static func makeLighting() -> [Entity] {
        // Dim neutral fill, aimed down-and-forward (a directional light emits
        // along its -Z; tilting -55° about X points it at the floor).
        let fill = Entity()
        fill.name = "FillLight"
        let fillLight = DirectionalLightComponent(
            color: color(0xFFF6E8),
            intensity: 600
        )
        
        fill.components.set(fillLight)
        fill.orientation = simd_quatf(angle: -.pi * 0.30, axis: [1, 0, 0])

        // Two violet accent pools, low and toward the back wall.
        let accentLeft = makeAccentLight(name: "AccentLightL", at: [-6, 1.2, -3.5])
        let accentRight = makeAccentLight(name: "AccentLightR", at: [6, 1.2, -3.5])

        return [fill, accentLeft, accentRight]
    }

    private static func makeAccentLight(name: String, at position: SIMD3<Float>) -> Entity {
        let entity = Entity()
        entity.name = name
        entity.components.set(
            PointLightComponent(
                color: color(0x8B5CF6),   // Aether Violet
                intensity: 2200,
                attenuationRadius: 14
            )
        )
        entity.position = position
        return entity
    }

    // MARK: - Color

    /// Build a `UIColor` from a 24-bit RGB hex literal — the RealityKit-side
    /// twin of `AetherDesign`'s `Color(hex:)`, kept here because RealityKit
    /// materials/lights take `UIColor`, not SwiftUI `Color`.
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
