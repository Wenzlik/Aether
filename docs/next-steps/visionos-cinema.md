# Aether Immersive Cinema — visionOS V1 Foundation

> **Branch:** `feature/aether-cinema` (visionOS only; iOS/tvOS untouched).
> **Goal:** a reliable, native, premium cinema foundation — the quality bar is
> Apple TV+ / Disney+ / Infuse-visionOS, *not* an iPad-app-in-space or a
> RealityKit tech demo.
> **This V1 is a foundation, not a feature show.** No custom controls, no custom
> environments beyond Dark Theater, no shaders/particles. Reliability first.

This rewrite supersedes the earlier custom-renderer design after a hard lesson
on device (see Part 1). It is grounded in Apple's documented immersive-media
pattern (WWDC24 10115, WWDC23 10070, AVKit "Adopting the system player interface
in visionOS", *Destination Video* sample).

---

## Part 1 — Architecture Review

### What we built first (and why it failed)

The first prototype rendered the video **ourselves** inside the immersive space —
a RealityKit screen entity (tried both `VideoMaterial` and
`VideoPlayerComponent`) plus a **fully custom control plane** (scrubber, track
menus) as an attachment, with manual entity scaling for screen-size presets.

On device this produced a cascade of failures:

| Symptom | Root cause |
|---|---|
| Video rendered as scrambled blocks (`VideoMaterial`) | A raw `VideoMaterial` sampler doesn't handle the HDR / decode pipeline; only the system player does. |
| Black / artefacted screen when scaled up (`VideoPlayerComponent`) | Scaling a `VideoPlayerComponent` entity past ~native size degrades and then breaks its rendering. |
| Presets barely differed / tiny screen | Capping scale to avoid the break left everything small; a far screen vs a near control panel looked tiny. |
| Custom controls "double" then "missing" | We fought the system player's own transport — duplicating it, then hiding it and losing transport entirely. |
| App window floated in the cinema; black screen on re-entry | Dismissing/reopening the `WindowGroup` re-ran `AppSession.start()` and churned the immersive view lifecycle. |

**The meta-root-cause:** we re-implemented things visionOS already owns —
**video rendering, screen sizing, and playback controls.** Each is a system
responsibility on visionOS; fighting them is why the prototype was fragile.

### The documented Apple pattern (what premium apps actually do)

1. **`AVPlayerViewController` in fullscreen** is the player — native transport,
   scrubbing, audio/subtitle selection, AirPlay, HLS — and it **participates in
   system docking**.
2. When the app **opens an `ImmersiveSpace`, the fullscreen video screen
   automatically "docks" into it**, anchored at a system-guaranteed size and
   angle, and the **controls detach and come closer**. (Default location chosen
   by the system; a `DockingRegion` component customises it.)
3. The **environment** (our Dark Theater) is RealityKit content in the immersive
   space. The "theater" feel = a dark scene + **dimmed passthrough**
   (`surroundingsEffect` tint + content brightness), not a video surface we draw.

This is Apple's *Destination Video* "Studio environment" architecture.

**Why this is the right foundation:** the system owns rendering, sizing, and
controls — the three things that broke for us. We own only *state* (are we in the
cinema, with what item) and the *environment art*. Small, stable surface.

### Risks

- **Docking presentation glue** — the one piece to verify first on device.
- **No Reality Composer Pro asset pipeline yet** — V1 uses the **default docking
  location** + a procedural dark environment, so no authored `.usda` /
  `DockingRegion` is needed. Custom `DockingRegion` is Phase 2.
- **Simulator ≠ device** for immersion, dimming, and docking — judge on hardware.

---

## Part 2 — Recommended Architecture & Plan

### Ownership (single source of truth)

| Concern | Owner |
|---|---|
| Playback (AVPlayer, resume, transcode) | `PlaybackSession` (AetherCore) — **unchanged** |
| Player UI + controls + fullscreen | **`AVPlayerViewController`** (system) via `SystemVideoPlayer` — **reused** |
| Cinema state (in/out, current item) | **`CinemaManager`** — `@MainActor @Observable`, the single source of truth |
| Immersive environment (Dark Theater) | `DarkTheaterView` (RealityKit, environment only — no video, no controls) |
| Enter/exit + space lifecycle | `RootTabView` (window context) driven by `CinemaManager` |

`CinemaManager` replaces `CinemaCoordinator`. It holds the playback context
(`item` / `source` / `startAt`) + a phase, and signals enter/exit. It never
touches `PlaybackSession` internals or rendering.

### Enter / exit flow

```
Detail → "Watch in Cinema"
        └─ CinemaManager.present(item, source, startAt)       // state + intent
RootTabView observes the intent:
        ├─ openImmersiveSpace("AetherCinema")  → Dark Theater appears
        └─ present AVPlayerViewController (fullscreen)         // system docks it in
Exit (native Done / Leave):
        ├─ dismiss the player
        └─ dismissImmersiveSpace  → CinemaManager → idle
```

One immersive space id, one environment. **No window dismiss/reopen** (the
fragile part last time) — the window stays; the video *docks out of it* into the
space, which is the system behaviour.

### Screen system (extensible, V1 = system default)

`CinemaScreenPreset` (Medium / Large / IMAX / Wall) stays as the extensibility
seam, but **V1 uses the system's default docking size** (Apple guarantees a good
"Large"). Presets become real once we author a custom `DockingRegion` (Phase 2).
Not sizing anything ourselves is *why* V1 is reliable.

### Controls

**Native AVKit only.** No custom scrubber/timeline/RealityKit control surface.
`CinemaControlsView` is deleted.

### Files

- `AetherCore/Cinema/CinemaScreenPreset.swift` — keep (future presets).
- `AetherCore/Cinema/CinemaEnvironment.swift` — keep (future environments).
- `Aether/Sources/Cinema/CinemaManager.swift` — **new** (was `CinemaCoordinator`).
- `Aether/Sources/Cinema/DarkTheaterView.swift` — **new** (environment only;
  replaces `CinemaImmersiveView` + `CinemaTheater`).
- `Aether/Sources/Cinema/CinemaControlsView.swift` — **deleted**.
- `Aether/Sources/Cinema/CinemaImmersiveView.swift` / `CinemaTheater.swift` —
  **deleted**.
- `SystemVideoPlayer.swift` / `PlayerView.swift` — **reused** as-is (native player).
- `AetherApp.swift`, `RootTabView.swift`, `DetailView.swift` — wire the flow.

---

## Part 3 — Production Implementation

On this branch:

- `CinemaManager` is the only cinema state. `RootTabView` opens the space +
  presents the player on its intent, and tears both down on exit.
- `DarkTheaterView` renders a dark RealityKit environment + a subtle
  Aether-violet accent light and dims passthrough. It draws **no video** — the
  system docks the player here.
- The player is the existing `AVPlayerViewController` (`SystemVideoPlayer`),
  unchanged → controls / scrubbing / track selection are 100% native.

### Verify first on device (the one risk)

Documented behaviour: fullscreen `AVPlayerViewController` + open immersive space
⇒ video docks. Confirm the player visibly **docks into the Dark Theater** (screen
anchored in the environment, controls detached). If it doesn't dock, the fix is
entirely in the *player presentation* (fullscreen), not the rest of the
architecture.

---

## Future (designed-for, NOT in V1)

- **Phase 2 — Enhanced Cinema:** authored Dark Theater `.usda` + custom
  `DockingRegion` (precise placement) → real Medium/Large/IMAX presets; floor
  media reflections; smoother transitions.
- **Phase 3 — Premium Immersion:** Nebula / Deep Space / Orbit Station (already
  enumerated in `CinemaEnvironment`).
- **Phase 4 — Advanced:** SharePlay (`AVPlaybackCoordinator` +
  `AVGroupExperienceCoordinator`), Spatial Personas, synchronized viewing.

The V1 ownership split (system owns playback/controls/size; we own state +
environment) makes all of these additive.
