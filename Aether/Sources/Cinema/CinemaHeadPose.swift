#if os(visionOS)
import ARKit
import QuartzCore
import simd
import os

/// One-shot reader of the current **head (device) pose**, used to place the
/// cinema screen along the user's gaze when they enter the cinema — so it lands
/// where they're actually looking (e.g. overhead when reclined), the way the
/// system Home menu does, instead of always docking horizontally in front.
///
/// **Why this is needed.** When an `ImmersiveSpace` opens, RealityKit's world
/// origin is **gravity-aligned**: its `-Z` points only at the *horizontal*
/// direction the user faced, with pitch discarded. The authored
/// `CustomDockingRegion` therefore sits at a fixed `-Z`, so a reclined viewer
/// looking straight up still gets the screen horizontally "in front" of them.
/// The system recenter gesture (hold the Digital Crown) doesn't fix this — it's
/// gravity-aligned too. The only way to honour the true gaze (pitch included) is
/// to read the device anchor from ARKit and orient the dock to it.
///
/// `WorldTrackingProvider`'s device anchor is the one ARKit data source that
/// needs **no** privacy usage string / authorization prompt (unlike hand
/// tracking or scene reconstruction) — it's the same pose that backs all
/// immersive rendering.
@MainActor
final class CinemaHeadPose {
    private let session = ARKitSession()
    private let worldTracking = WorldTrackingProvider()
    private var running = false

    private static let log = Logger(subsystem: "cz.zmrhal.aether", category: "cinema")

    /// Run world tracking and return the **first** available head transform in
    /// the immersive space's world coordinates, polling briefly while ARKit
    /// warms up. Returns `nil` if tracking is unsupported or no pose arrives
    /// within `timeout` — the caller then falls back to the gravity-aligned
    /// authored placement.
    ///
    /// The transform's translation (column 3) is the head position; its `-Z`
    /// column is the gaze-forward direction.
    func firstHeadTransform(timeout: Duration = .seconds(1)) async -> simd_float4x4? {
        guard await start() else { return nil }

        // Poll: queryDeviceAnchor returns nil for a beat after the provider
        // starts running. ~60 Hz cadence; bail at the timeout.
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let transform = currentHeadTransform() { return transform }
            try? await Task.sleep(for: .milliseconds(16))
        }
        Self.log.debug("head pose: no device anchor within timeout → gravity-aligned fallback")
        return nil
    }

    /// The current head transform, or `nil` if tracking isn't running/ready.
    func currentHeadTransform() -> simd_float4x4? {
        guard worldTracking.state == .running,
              let anchor = worldTracking.queryDeviceAnchor(atTimestamp: CACurrentMediaTime())
        else { return nil }
        return anchor.originFromAnchorTransform
    }

    /// Stop the ARKit session (frees the tracker when the cinema closes).
    func stop() {
        session.stop()
        running = false
    }

    /// Start world tracking once. Returns `false` if unsupported or it failed to
    /// run; `true` once running.
    @discardableResult
    private func start() async -> Bool {
        if running { return true }
        guard WorldTrackingProvider.isSupported else {
            Self.log.debug("head pose: WorldTrackingProvider unsupported")
            return false
        }
        do {
            try await session.run([worldTracking])
            running = true
            return true
        } catch {
            Self.log.error("head pose: failed to run world tracking: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
#endif
