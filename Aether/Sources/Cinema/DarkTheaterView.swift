#if os(visionOS)
import SwiftUI
import RealityKit
import UIKit
import CoreGraphics
import AVFoundation
import Combine
import os
import AetherCore

/// The Dark Theater immersive **environment** — and only the environment.
///
/// It draws a premium dark screening room. It does **not** render the movie: the
/// system docks the native `AVPlayerViewController` into this space (see
/// `docs/next-steps/visionos-cinema.md`). Keeping video out of here is the whole
/// point — the system owns rendering, sizing, and controls.
///
/// **V2 (Enhanced Cinema):** the empty black-wall / gray-floor / purple-line look
/// is replaced with image-based lighting from a code-drawn dark-violet gradient,
/// a glossy clearcoat floor that pools the room + screen glow, an enclosing dark
/// skybox, restrained emissive cove strips + a screen-bloom panel, grounding
/// shadows, and a gentle "lights dimming" passthrough fade on enter. It is still
/// 100% procedural — no Reality Composer Pro assets — so it ships with no asset
/// pipeline and stays the reliable fallback. (Real Medium/Large/IMAX docking
/// presets + a literal moving-video floor reflection need authored `.usda`
/// assets and are a separate track — see the design doc.)
struct DarkTheaterView: View {
    /// Cinema state — the theater reads the live size + seat off it (reactively)
    /// and resets it when playback ends.
    let cinema: CinemaManager
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    /// Drives the gentle passthrough dim on enter ("house lights down"). Starts
    /// off so the room fades dark rather than snapping.
    @State private var dimmed = false
    /// References into the loaded scene so the live controls can re-apply size +
    /// seat without rebuilding it. A reference type → mutating it never trips a
    /// SwiftUI update (no re-render loop).
    @State private var refs = CinemaSceneRefs()

    private static let log = Logger(subsystem: "cz.zmrhal.aether", category: "cinema")
    private static let controlPanelID = "cinemaControls"

    var body: some View {
        RealityView { content, attachments in
            // Prefer the authored Dark Theater (its `DockingRegion` sizes the
            // docked screen + reflective floor); fall back to the procedural
            // room if the asset can't load.
            let root: Entity
            if let authored = await Self.loadAuthoredEnvironment() {
                root = authored
            } else {
                // No cable to test on device → this log + the ones in
                // applyLayout are the TestFlight telemetry for which path ran.
                Self.log.debug("authored env: \(Self.sceneName, privacy: .public).usda failed to load → procedural room")
                root = await Self.makeEnvironment()
            }
            content.add(root)
            refs.root = root
            refs.dock = root.findEntity(named: Self.dockEntityName)
            applyLayout()

            // Floating glass control (size + seat), parked low and close to the
            // viewer — NOT a child of the room (stays put as the seat slides).
            // Low + near so it sits *below* the screen rectangle (even at the
            // largest preset / during playback the docked video doesn't cover
            // it) and stays reachable. Tune Y on device.
            if let panel = attachments.entity(for: Self.controlPanelID) {
                panel.position = SIMD3<Float>(0, 0.35, -1.15)
                content.add(panel)
            }
        } attachments: {
            Attachment(id: Self.controlPanelID) {
                CinemaControlPanel(cinema: cinema)
            }
        }
        // Live: re-apply the region/room when the in-cinema control changes
        // size or seat, then ask the player to re-dock so the system re-fits the
        // already-docked screen to the new region (it only reads it at attach).
        // Order matters — update the region first, then request the re-dock.
        .onChange(of: cinema.screenPreset) { _, _ in applyLayout(); cinema.requestRedock() }
        .onChange(of: cinema.seat) { _, _ in applyLayout(); cinema.requestRedock() }
        // Gentle "house lights down": ramp passthrough to dark on enter instead
        // of a hard cut. Only visible on device (Simulator barely dims).
        .preferredSurroundingsEffect(dimmed ? .systemDark : nil)
        .onAppear {
            Self.log.debug("DarkTheater appeared (space open)")
            withAnimation(.easeInOut(duration: 1.4)) { dimmed = true }
        }
        .onDisappear { Self.log.debug("DarkTheater disappeared (space closed)") }
        // Authoritative exit: this view lives for as long as the immersive space
        // is open (it *is* the space's scene), so its end-of-playback observer
        // fires reliably even when the docked player detaches the window's view
        // tree. When the movie ends, close the space and reset cinema state;
        // `DetailView` reacts to `cinema` going idle by dropping the player.
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { _ in
            Self.log.debug("DarkTheater: didPlayToEnd → dismiss space + cinema.end()")
            Task { @MainActor in
                await dismissImmersiveSpace()
                cinema.end()
            }
        }
    }

    /// Apply the live `cinema.screenPreset` (size) and `cinema.seat` (row) to the
    /// loaded scene. **Idempotent** — safe to call repeatedly from the controls —
    /// because every value is absolute, never accumulated.
    @MainActor
    private func applyLayout() {
        // Size: prefer the documented `DockingRegionComponent.width` knob (height
        // follows at 2.4:1, per WWDC24); fall back to a uniform transform scale
        // if the component doesn't resolve. width = authored baseline × scale,
        // so `.medium` (×1.0) is exactly the authored dock.
        if let dock = refs.dock {
            let scale = cinema.screenPreset.relativeScale
            if var region = dock.components[DockingRegionComponent.self] {
                if refs.baselineDockWidth == nil { refs.baselineDockWidth = region.width }
                region.width = (refs.baselineDockWidth ?? region.width) * scale
                dock.components.set(region)
            } else {
                dock.scale = SIMD3<Float>(repeating: scale)
            }
        }
        // Seat: slide the whole room. -Z = back (screen farther), -Y = room down
        // so the viewer sits higher — a stadium rake where each row back is a
        // little higher. Absolute, anchored at the authored layout (.middle=0,0).
        if let root = refs.root {
            root.position = SIMD3<Float>(0, cinema.seat.yOffsetMetres, cinema.seat.zOffsetMetres)
        }
        Self.log.debug("cinema layout: size=\(cinema.screenPreset.rawValue, privacy: .public) (×\(cinema.screenPreset.relativeScale, privacy: .public)) seat=\(cinema.seat.rawValue, privacy: .public)")
    }

    // MARK: - Authored environment (Reality Composer Pro)

    /// Name of the authored scene in `RealityKitContent.rkassets` (the file is
    /// `AetherDarkTheater.usda`; its root prim shares the name).
    private static let sceneName = "AetherDarkTheater"
    /// Name of the entity that carries the authored `DockingRegion` — scaling it
    /// resizes the docked screen. Matches the `Player` prim in the `.usda`.
    private static let dockEntityName = "Player"

    /// Load the authored Dark Theater from the app bundle (the Reality Composer
    /// Pro `.rkassets`, compiled in as an app resource). Returns `nil` if the
    /// asset is missing, so the caller falls back to the procedural room. The
    /// scene carries a `DockingRegion` (sizing the docked screen) and a
    /// reflective floor.
    @MainActor
    private static func loadAuthoredEnvironment() async -> Entity? {
        try? await Entity(named: sceneName, in: .main)
    }

    // MARK: - Environment

    /// Build the premium Dark Theater. `@MainActor` because RealityKit entity /
    /// component initialisers are main-actor-isolated; `async` so the IBL +
    /// skybox textures can be generated off the render path. Values are a first
    /// pass — tune on device (Simulator misjudges scale, reflections, dimming).
    @MainActor
    private static func makeEnvironment() async -> Entity {
        let root = Entity()
        root.name = "DarkTheater"

        // Draw the dark-violet gradient once; both the IBL and the skybox use it
        // (it also carries the screen-glow band, so the "bloom" lives in the
        // lighting/reflection — never as an opaque panel between the audience and
        // the system-docked screen).
        let gradient = makeGradientImage()

        // Image-based lighting from that gradient is the primary light — soft and
        // cinematic, unlike two bare point lights. Tuned to stay dark but bright
        // enough that the glossy floor actually pools a reflection (TUNE ON
        // DEVICE — the Simulator misjudges this).
        var ibl: Entity?
        if let gradient { ibl = await makeIBL(from: gradient) }
        if let ibl { root.addChild(ibl) }

        // The floor is the one PBR surface that should reflect the environment,
        // so the IBL receiver goes on it directly (the component doesn't
        // propagate from the root to children). The skybox / cove are unlit and
        // don't need it.
        let floor = makeFloor()
        if let ibl {
            floor.components.set(ImageBasedLightReceiverComponent(imageBasedLight: ibl))
        }
        root.addChild(floor)
        if let gradient, let skybox = await makeSkybox(from: gradient) { root.addChild(skybox) }
        root.addChild(makeKeyLight())
        for cove in makeCoveLights() { root.addChild(cove) }

        return root
    }

    /// The image-based light entity, built from the code-drawn gradient. `nil`
    /// if the resource can't be generated (then the room falls back to the dim
    /// key light alone — still dark, just flatter).
    @MainActor
    private static func makeIBL(from image: CGImage) async -> Entity? {
        guard let resource = try? await EnvironmentResource(equirectangular: image) else { return nil }
        let ibl = Entity()
        ibl.name = "IBL"
        // `intensityExponent` is a power-of-two multiplier (−0.5 ≈ 0.71×). Kept
        // only slightly under unity so the glossy floor still picks up a visible
        // reflection of the gradient's glow band — a more negative value (the
        // first pass used −1.5 ≈ 0.35×) crushed the floor back to flat black.
        // TUNE ON DEVICE.
        ibl.components.set(ImageBasedLightComponent(source: .single(resource), intensityExponent: -0.5))
        return ibl
    }

    /// Near-black, glossy clearcoat floor. Low roughness + a clearcoat layer make
    /// it pool the IBL gradient and the screen-bloom band as a soft on-floor glow
    /// — the "luxury screening room" cue. (This reflects the *environment*, not
    /// the live picture; a literal video reflection needs an authored asset.)
    @MainActor
    private static func makeFloor() -> Entity {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color(0x0B0B0F))
        material.roughness = .init(floatLiteral: 0.18)
        material.metallic = .init(floatLiteral: 0.0)
        material.clearcoat = .init(floatLiteral: 1.0)
        material.clearcoatRoughness = .init(floatLiteral: 0.12)

        let floor = ModelEntity(mesh: .generatePlane(width: 60, depth: 60), materials: [material])
        floor.name = "Floor"
        // No GroundingShadowComponent here: the floor *is* the ground (its normal
        // faces up, so it can't cast a downward grounding shadow), and the room
        // has no hovering props to ground — the docked screen is system-owned and
        // must not be touched. Grounding shadows return only if we add real props.
        return floor
    }

    /// A large inverted sphere textured with the same dark gradient so the room
    /// reads as an enclosed space with depth instead of a flat black void.
    @MainActor
    private static func makeSkybox(from image: CGImage) async -> Entity? {
        guard let texture = try? await TextureResource(image: image, options: .init(semantic: .color))
        else { return nil }

        var material = UnlitMaterial()
        material.color = .init(tint: .white, texture: .init(texture))
        // Render both sides so the gradient is visible from inside the sphere
        // (default back-face culling would hide the interior we're standing in).
        material.faceCulling = .none

        let sphere = ModelEntity(mesh: .generateSphere(radius: 50), materials: [material])
        sphere.name = "Skybox"
        return sphere
    }

    /// One dim, warm key light from above-front. Kept low — the IBL does the
    /// ambient work — purely so the glossy floor gets a soft specular streak.
    /// (It does *not* steer shadows: grounding shadows ignore scene lights.)
    @MainActor
    private static func makeKeyLight() -> Entity {
        let entity = Entity()
        entity.name = "KeyLight"
        entity.components.set(DirectionalLightComponent(color: color(0xFFF4E6), intensity: 220))
        entity.orientation = simd_quatf(angle: -.pi * 0.34, axis: [1, 0, 0])
        return entity
    }

    /// Thin, dim violet emissive cove strips — a restrained brand accent that
    /// reads as architectural cove lighting, not two lamps (replaces V1's two
    /// bright point lights). The "front" run sits *behind* the screen plane so it
    /// glows at the base of the far wall rather than as a line between the
    /// audience and the docked screen; the side runs flank the seating. Calm, not
    /// neon.
    @MainActor
    private static func makeCoveLights() -> [Entity] {
        func strip(_ name: String, width: Float, depth: Float, at position: SIMD3<Float>) -> Entity {
            let entity = ModelEntity(
                mesh: .generatePlane(width: width, depth: depth),
                materials: [UnlitMaterial(color: color(0x2C1F52))]
            )
            entity.name = name
            entity.position = position
            return entity
        }
        return [
            strip("CoveFront", width: 11, depth: 0.05, at: [0, 0.012, -6.6]),
            strip("CoveLeft", width: 0.05, depth: 9, at: [-5.4, 0.012, -1.5]),
            strip("CoveRight", width: 0.05, depth: 9, at: [5.4, 0.012, -1.5]),
        ]
    }

    // MARK: - Procedural gradient

    /// Draw a 1024×512 equirectangular gradient used for both the IBL and the
    /// skybox: near-black at the nadir, rising to a charcoal-violet zenith, with a
    /// soft brighter glow toward the upper-front. The glow sits high on purpose —
    /// a flat floor's reflection samples the *upper* hemisphere, so that's where
    /// the on-floor pool comes from. Brightness + exact placement need on-device
    /// tuning (equirectangular yaw and Simulator lighting are unreliable here). No
    /// assets — pure Core Graphics.
    private static func makeGradientImage() -> CGImage? {
        let width = 1024, height = 512
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Vertical gradient: near-black nadir → charcoal-violet zenith. The top
        // carries the most energy because that's what the floor reflects.
        let colors = [
            color(0x050507).cgColor,   // nadir — floor never reflects this
            color(0x100D20).cgColor,   // horizon
            color(0x241D44).cgColor,   // zenith — charcoal violet, the floor's source
        ] as CFArray
        guard let gradient = CGGradient(
            colorsSpace: colorSpace, colors: colors, locations: [0.0, 0.5, 1.0]
        ) else { return nil }
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: 0, y: height),
            options: []
        )

        // Soft brighter glow high and centred (upper-front) — the screen's light
        // spilling into the dome, picked up as the pooled glow on the glossy
        // floor. Kept restrained so the room still reads dark.
        if let glow = CGGradient(
            colorsSpace: colorSpace,
            colors: [color(0x4A4072).cgColor, color(0x241D44).withAlphaComponent(0).cgColor] as CFArray,
            locations: [0.0, 1.0]
        ) {
            let center = CGPoint(x: CGFloat(width) / 2, y: CGFloat(height) * 0.80)
            context.drawRadialGradient(
                glow,
                startCenter: center, startRadius: 0,
                endCenter: center, endRadius: CGFloat(width) * 0.42,
                options: []
            )
        }

        return context.makeImage()
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

// MARK: - Scene references

/// Mutable handles into the loaded Dark Theater so the live controls can
/// re-apply size + seat without rebuilding the scene. A reference type, held in
/// `@State`, so mutating its fields never triggers a SwiftUI update.
@MainActor
private final class CinemaSceneRefs {
    var root: Entity?
    var dock: Entity?
    /// Authored `DockingRegion` width, captured once so size changes are
    /// absolute (`baseline × relativeScale`) rather than compounding.
    var baselineDockWidth: Float?
}

// MARK: - In-cinema control panel

/// Floating glass control inside the Dark Theater: screen **size** + **seat**
/// (row). Tapping updates `cinema`, which `DarkTheaterView` observes to resize
/// the docked screen and slide the room live. Mirrors Apple TV+'s in-environment
/// controls. Tuned for reach; positioned by `DarkTheaterView`.
private struct CinemaControlPanel: View {
    let cinema: CinemaManager

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
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
        .frame(width: 480)
        .glassBackgroundEffect()
    }

    @ViewBuilder
    private func row(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
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
