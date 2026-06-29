#if os(visionOS)
import SwiftUI
import RealityKit
import UIKit
import CoreGraphics
import AVFoundation
import Combine
import os
import simd
import AetherCore

/// The Dark Theater immersive **environment** — and only the environment.
///
/// It draws a premium dark screening room. It does **not** render the movie: the
/// system docks the native `AVPlayerViewController` into this space (see
/// `docs/next-steps/visionos-cinema.md`). Keeping video out of here is the whole
/// point — the system owns rendering, sizing, and controls.
///
/// **V2 (Enhanced Cinema):** the empty black-wall / gray-floor / purple-line look
/// is replaced with image-based lighting from a code-drawn warm dark gradient
/// (intimate screening-room amber, matched to the authored scene), a glossy
/// clearcoat floor that pools the room + screen glow, an enclosing dark skybox,
/// restrained warm emissive cove strips + a screen-bloom panel, grounding
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
    /// Pause the theater's procedural/decorative rendering when the space isn't
    /// active (app backgrounded) to cut compositor work — the docked video is
    /// kept; only the room is hidden.
    @Environment(\.scenePhase) private var scenePhase

    /// Drives the gentle passthrough dim on enter ("house lights down"). Starts
    /// off so the room fades dark rather than snapping.
    @State private var dimmed = false
    /// References into the loaded scene so the live controls can re-apply size +
    /// seat without rebuilding it. A reference type → mutating it never trips a
    /// SwiftUI update (no re-render loop).
    @State private var refs = CinemaSceneRefs()
    /// Reads the head pose once at entry so the screen docks along the user's
    /// real gaze (see `placeScreenAlongGaze`). Held for the space's lifetime so
    /// the ARKit session is torn down on exit.
    @State private var headPose = CinemaHeadPose()

    private static let log = Logger(subsystem: "cz.zmrhal.aether", category: "cinema")

    var body: some View {
        // No SwiftUI/RealityKit attachment for the controls: Screen-size + Seat
        // live in the native player's Info panel as a "Theater" tab (see
        // `SystemVideoPlayer` → `customInfoViewControllers` / `CinemaInfoControls`).
        // A floating attachment can't composite over the system-docked video — at
        // the larger screen sizes it hid *behind* the picture — and an always-
        // visible handle cluttered the view. The Info-panel tab renders in the
        // system layer (always in front) and is reached by tapping the docked
        // video. This view is now purely the environment.
        RealityView { content in
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
            // Lay out immediately at the authored placement so the room is sized
            // without waiting on ARKit, then read the head pose (a beat while world
            // tracking warms up) and re-lay-out along the real gaze — overhead when
            // reclined — instead of the gravity-aligned -Z.
            applyLayout()
            if let head = await headPose.firstHeadTransform() {
                refs.headTransform = head
                applyLayout()
                // The pose can arrive *after* the player has already expanded
                // (docked) at the authored -Z, so re-dock to re-read the gaze-
                // aligned region. If the expand hasn't happened yet this is a
                // harmless no-op — that later expand reads the updated region.
                cinema.requestRedock()
            }
        }
        // Live: re-apply the region/room when the in-cinema control changes
        // size or seat, then ask the player to re-dock so the system re-fits the
        // already-docked screen to the new region (it only reads it at attach).
        // Order matters — update the region first, then request the re-dock.
        .onChange(of: cinema.screenPreset) { _, _ in applyLayout(); cinema.requestRedock() }
        .onChange(of: cinema.seat) { _, _ in applyLayout(); cinema.requestRedock() }
        // Battery: when the space goes inactive (app backgrounded), hide the
        // room so the compositor isn't rendering the full 3D environment behind
        // the lock screen; re-show on return. The docked video's subtree is left
        // enabled so playback is untouched.
        .onChange(of: scenePhase) { _, phase in setEnvironmentActive(phase == .active) }
        // Gentle "house lights down": ramp passthrough to dark on enter instead
        // of a hard cut. Only visible on device (Simulator barely dims).
        .preferredSurroundingsEffect(dimmed ? .systemDark : nil)
        .onAppear {
            Self.log.debug("DarkTheater appeared (space open)")
            withAnimation(.easeInOut(duration: 1.4)) { dimmed = true }
        }
        .onDisappear {
            Self.log.debug("DarkTheater disappeared (space closed)")
            headPose.stop()
        }
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
        // Seat FIRST: slide the whole room so the floor lands at its final
        // world-Y before the dock Y is computed below. `.middle` Z = 0.
        // -Z = back (screen farther); -Y = room down → viewer looks slightly
        // down at the screen (stadium rake). Absolute, never accumulated.
        if let root = refs.root {
            root.position = SIMD3<Float>(0, cinema.seat.yOffsetMetres, cinema.seat.zOffsetMetres)
        }

        // Size: prefer the documented `DockingRegionComponent.width` knob (height
        // follows at 2.4:1, per WWDC24); fall back to a uniform transform scale
        // if the component doesn't resolve. width = authored baseline × scale,
        // so `.medium` (×1.0) is exactly the authored dock.
        if let dock = refs.dock {
            let scale = cinema.screenPreset.relativeScale
            let screenHeight: Float
            if var region = dock.components[DockingRegionComponent.self] {
                if refs.baselineDockWidth == nil { refs.baselineDockWidth = region.width }
                let width = (refs.baselineDockWidth ?? region.width) * scale
                region.width = width
                dock.components.set(region)
                screenHeight = width / CinemaScreenPreset.dockingAspectRatio
            } else {
                // No resolved DockingRegion (rare fallback): uniform scale.
                dock.scale = SIMD3<Float>(repeating: scale)
                screenHeight = cinema.screenPreset.heightMetres
            }

            // Placement. Prefer the user's real gaze (head pose) so the screen
            // lands where they're looking — overhead when reclined — like the
            // system Home menu. Fall back to the gravity-aligned authored
            // placement when no head pose is available.
            if let headTransform = refs.headTransform {
                placeScreenAlongGaze(dock: dock, headTransform: headTransform)
            } else {
                // Anchor the *bottom edge* a fixed clearance above the theater floor
                // in **world space** (#357 revisited). The theater floor sits at world
                // Y = seat.yOffsetMetres (the root has just been placed above). Using
                // `setPosition(relativeTo: nil)` is essential: the authored `Video_Dock`
                // parent entity sits ~2.5 m above the root in the USDA, so assigning
                // `dock.position.y` in local space silently adds that offset and pushes
                // the screen ~2.5 m too high (#357 regression).
                let floorWorldY = cinema.seat.yOffsetMetres
                let targetWorldY = floorWorldY + Self.screenBottomClearance + screenHeight / 2
                let worldPos = dock.position(relativeTo: nil)
                dock.setPosition(SIMD3<Float>(worldPos.x, targetWorldY, worldPos.z), relativeTo: nil)
            }
        }

        Self.log.debug("cinema layout: size=\(cinema.screenPreset.rawValue, privacy: .public) (×\(cinema.screenPreset.relativeScale, privacy: .public)) seat=\(cinema.seat.rawValue, privacy: .public) gaze=\(refs.headTransform != nil, privacy: .public)")
    }

    /// Place the docked screen along the user's **actual gaze** at entry, so it
    /// lands where they're looking — the way the system Home menu appears — rather
    /// than at the gravity-aligned authored `-Z` (which left a reclined viewer's
    /// screen horizontally "in front" instead of overhead). The dark room stays
    /// gravity-aligned as a backdrop; only the screen follows the head.
    ///
    /// `headTransform` is the device pose in world space: column 3 is the head
    /// position, its `-Z` axis is gaze-forward, its `+Y` axis the head's up. We
    /// sit the screen a comfortable distance down that ray and billboard it to
    /// face the viewer (head orientation spun 180° about its own up), so it stays
    /// upright relative to the head even when reclined. Idempotent — `applyLayout`
    /// re-runs it on every size/seat change using the entry pose stored in `refs`.
    @MainActor
    private func placeScreenAlongGaze(dock: Entity, headTransform: simd_float4x4) {
        let headRotation = simd_quatf(headTransform)
        let headPos = SIMD3<Float>(headTransform.columns.3.x, headTransform.columns.3.y, headTransform.columns.3.z)
        let gazeForward = simd_normalize(headRotation.act(SIMD3<Float>(0, 0, -1)))

        // Distance down the gaze ray: the authored screen distance, captured once
        // *before* we first move the dock, nudged by the Seat control (front =
        // closer, back = farther — `+Z` seat offset slides the screen toward us).
        if refs.baselineDockDistance == nil {
            refs.baselineDockDistance = simd_length(dock.position(relativeTo: nil))
        }
        let distance = max(2.0, (refs.baselineDockDistance ?? 8.0) - cinema.seat.zOffsetMetres)

        dock.setPosition(headPos + gazeForward * distance, relativeTo: nil)
        // Face the viewer: the head's own orientation turned 180° about its up, so
        // the screen's front looks back along the gaze and is upright relative to
        // the head. (If the docked video reads back-to-front on device, drop this
        // 180° spin — TUNE ON DEVICE; docking-region orientation isn't testable in
        // the Simulator.)
        dock.setOrientation(headRotation * simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0)), relativeTo: nil)
    }

    /// Show/hide the theater's *room* (everything except the video-dock subtree)
    /// with the app's active state, so the compositor isn't drawing the full 3D
    /// environment while backgrounded. The dock subtree stays enabled so the
    /// docked video is untouched; in the procedural fallback (no dock) the whole
    /// room toggles — system docking is independent of these entities. Reversible
    /// (`isEnabled`), so it restores cleanly on return to foreground.
    @MainActor
    private func setEnvironmentActive(_ active: Bool) {
        guard let root = refs.root else { return }
        for child in root.children {
            if child.findEntity(named: Self.dockEntityName) != nil { continue }  // keep the dock
            child.isEnabled = active
        }
        Self.log.debug("cinema env rendering \(active ? "resumed" : "paused", privacy: .public)")
    }

    // MARK: - Authored environment (Reality Composer Pro)

    /// Name of the authored scene in `RealityKitContent.rkassets` (the file is
    /// `AetherDarkTheater.usda`; its root prim shares the name).
    private static let sceneName = "AetherDarkTheater"
    /// Name of the entity that carries the authored `DockingRegion` — scaling it
    /// resizes the docked screen. Matches the `Player` prim in the `.usda`.
    private static let dockEntityName = "Player"

    /// Clearance (metres) the docked screen's bottom edge holds above the floor at
    /// every size. The screen grows upward from this line instead of about its
    /// centre, so it never clips the floor (#357). First pass — tune on device.
    private static let screenBottomClearance: Float = 0.6

    /// Load the authored Dark Theater from the app bundle (the Reality Composer
    /// Pro `.rkassets`, compiled in as an app resource). Returns `nil` if the
    /// asset is missing, so the caller falls back to the procedural room. The
    /// scene carries a `DockingRegion` (sizing the docked screen) and a
    /// reflective floor.
    @MainActor
    private static func loadAuthoredEnvironment() async -> Entity? {
        try? await Entity(named: sceneName, in: .main)
    }

    // MARK: - Environment look

    /// The procedural Dark Theater's tunable palette + light intensities, in one
    /// documented block so the on-device tuning surface isn't hex literals
    /// scattered across the `make*` builders.
    ///
    /// **#358:** darkened and pulled toward neutral so the room recedes behind a
    /// dark, low-key film. The old amber-brown drove *both* the visible skybox and
    /// the IBL, washing the whole room (and the floor pool) warm; a low-key film
    /// (Pirates) competed badly. The room should read as a near-black screening
    /// room that disappears around the screen — but the IBL stays bright enough
    /// that the glossy floor still pools a faint screen-bloom (the "screening
    /// room" cue); don't crush it to flat black. Tune on device.
    private enum Style {
        /// Vertical skybox/IBL gradient, nadir → zenith. The top carries the most
        /// energy because a flat floor reflects the *upper* hemisphere.
        static let gradientNadir: UInt32   = 0x070402   // floor never reflects this
        static let gradientHorizon: UInt32 = 0x0C0905
        static let gradientZenith: UInt32  = 0x140E08   // the floor's reflected source
        /// Soft screen-bloom band high in the dome → pooled on the glossy floor.
        static let glowColor: UInt32           = 0x2A1D0E
        static let glowRadiusFraction: CGFloat = 0.30    // × image width (smaller, dimmer bloom)
        /// IBL strength as a power-of-two exponent (−1.0 ≈ 0.5×). Halved from the
        /// old −0.5 (≈0.71×) so the room recedes, but kept off the −1.5 (≈0.35×)
        /// first pass that crushed the floor pool to flat black.
        static let iblIntensityExponent: Float = -1.0
        /// Near-black warm-wood floor (kept; the IBL pool reads against it).
        static let floorColor: UInt32 = 0x150F0A
        /// Architectural cove accent — thin warm strips, dimmed to a faint line.
        static let coveColor: UInt32 = 0x301A0A
        /// Dim warm key for a soft floor specular; the IBL does the ambient work.
        static let keyLightColor: UInt32     = 0xFFD9A0
        static let keyLightIntensity: Float  = 120
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

        // Draw the warm dark gradient once; both the IBL and the skybox use it
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
        // Strength lives in `Style.iblIntensityExponent` (a power-of-two
        // multiplier) — see its doc for the dark-but-not-crushed rationale.
        ibl.components.set(ImageBasedLightComponent(source: .single(resource), intensityExponent: Style.iblIntensityExponent))
        return ibl
    }

    /// Near-black, glossy clearcoat floor. Low roughness + a clearcoat layer make
    /// it pool the IBL gradient and the screen-bloom band as a soft on-floor glow
    /// — the "luxury screening room" cue. (This reflects the *environment*, not
    /// the live picture; a literal video reflection needs an authored asset.)
    @MainActor
    private static func makeFloor() -> Entity {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color(Style.floorColor))   // warm dark wood
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
        entity.components.set(DirectionalLightComponent(color: color(Style.keyLightColor), intensity: Style.keyLightIntensity))
        entity.orientation = simd_quatf(angle: -.pi * 0.34, axis: [1, 0, 0])
        return entity
    }

    /// Thin, dim warm emissive cove strips — a restrained amber accent that
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
                materials: [UnlitMaterial(color: color(Style.coveColor))]
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
    /// skybox: near-black at the nadir, rising to a dark, near-neutral warm zenith
    /// (#358 — recedes behind the film), with a soft, restrained glow toward the
    /// upper-front. The glow sits high on purpose —
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

        // Vertical gradient: near-black nadir → warm amber-brown zenith. The top
        // carries the most energy because that's what the floor reflects.
        let colors = [
            color(Style.gradientNadir).cgColor,    // nadir — floor never reflects this
            color(Style.gradientHorizon).cgColor,  // horizon
            color(Style.gradientZenith).cgColor,   // zenith — the floor's reflected source
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
            colors: [color(Style.glowColor).cgColor, color(Style.glowColor).withAlphaComponent(0).cgColor] as CFArray,
            locations: [0.0, 1.0]
        ) {
            let center = CGPoint(x: CGFloat(width) / 2, y: CGFloat(height) * 0.80)
            context.drawRadialGradient(
                glow,
                startCenter: center, startRadius: 0,
                endCenter: center, endRadius: CGFloat(width) * Style.glowRadiusFraction,
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
    /// Authored screen distance (metres from origin to the dock), captured once
    /// before gaze placement first moves the dock, so the gaze-aligned distance
    /// stays absolute rather than compounding across size/seat changes.
    var baselineDockDistance: Float?
    /// The head pose captured at cinema entry (world space), or `nil` if ARKit
    /// gave none — then placement falls back to the gravity-aligned authored
    /// position. Held so `applyLayout` can re-apply gaze placement on size/seat
    /// changes without re-reading the head (the screen stays where it was placed,
    /// matching the Home-menu metaphor).
    var headTransform: simd_float4x4?
}

// The in-cinema Screen-size + Seat controls used to live here as a floating
// `CinemaControlPanel` attachment. They now live in the native player's Info
// panel as a "Theater" tab (see `CinemaInfoControls` +
// `SystemVideoPlayer.customInfoViewControllers`): a RealityKit attachment can't
// composite over the system-docked video (it hid behind the larger screens), and
// an always-visible handle cluttered the view. The Info-panel tab renders in
// front, survives docking, and is reached by tapping the docked video.
#endif
