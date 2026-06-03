# Aether Cinema — visionOS Architecture Proposal

> **Status:** design draft (local, pre-implementation). Not yet a ROADMAP
> promise — see *Roadmap placement* at the bottom.
> **Scope:** visionOS only. Everything here is gated behind `#if os(visionOS)`
> in the app target, or lives in `AetherCore` as cross-platform-safe value
> types. iOS and tvOS are unaffected.
> **North star:** *the media experience Apple never built for personal
> libraries.* Cinema is a **presentation**, not a new player.

---

## 0. The one decision everything else hangs on

`PlaybackSession` (actor, `AetherCore/Playback/`) already owns the single
`AVPlayer` and vends it via `currentAVPlayer()`. The existing
`AVPlayerViewController`-based `PlayerView` is just *one* renderer of that
player.

**Cinema Mode is a second renderer of the same `AVPlayer`** — a RealityKit
screen entity instead of an AVKit view controller. The playback engine,
resume loop, transcode warm-up, offline override, and `MediaSource`
resolution stay byte-for-byte identical. Cinema never imports `Playback/`
internals; it reads the vended `AVPlayer` and calls the existing
`PlayerStateViewModel` commands (`play` / `pause` / `seek`).

This satisfies the spec's hard constraint ("Cinema Mode must not introduce
dependencies into the playback engine") **for free**, because the seam
already exists.

```
                 PlaybackSession (actor)  ── unchanged ──┐
                         │ currentAVPlayer()             │
            ┌────────────┴─────────────┐                 │
            ▼                           ▼                 │
   PlayerView (AVKit)        CinemaImmersiveView          │
   Window Mode               (RealityKit VideoPlayer)     │
   iOS / tvOS / visionOS     visionOS only                │
            └───────────── same player, same VM ──────────┘
```

---

## 1. visionOS architecture proposal

Three layers, mapping onto the spec's "Technical Architecture" section, slotted
into Aether's existing module rules (`Aether/` thin, `AetherCore/` the brain):

| Layer | Lives in | New? | Notes |
|---|---|---|---|
| **Playback** | `AetherCore/Playback/` | **No change** | Reused as-is. `AVPlayer` / `AVQueuePlayer` already covered. |
| **Media Sources** | `AetherCore/MediaSources/` | **No change** | Plex + Jellyfin + Downloads already produce `MediaItem` + `resolvePlayback`. Cinema is source-agnostic, same as the rest of the app. |
| **Environment (state + value types)** | `AetherCore/Cinema/` | **New, cross-platform** | Pure `Sendable` value types + a preferences store. Compiles on iOS/tvOS too (they just never instantiate the views). |
| **Environment (RealityKit scene)** | `Aether/Sources/Cinema/` | **New, `#if os(visionOS)`** | The theater, the screen, the controls. App-target glue, exactly where AGENTS.md says platform UI goes. |
| **State (cinema session)** | `Aether/Sources/Cinema/` | **New, `#if os(visionOS)`** | `@MainActor @Observable` coordinator, owns immersive-space lifecycle + screen/environment selection. |

**Why split the Environment layer across both modules:** the *descriptors*
(which presets exist, their physical sizes, persisted preferences) are data and
must round-trip through `Codable` + a store — that belongs in `AetherCore` and
must compile everywhere (module rule #4). The *RealityKit construction* is
visionOS-only UI and belongs in the app target (module rule #1). This is the
same split Downloads already uses (`DownloadStore` in Core, Storage views in
app).

---

## 2. Recommended app structure

```
AetherCore/Sources/AetherCore/Cinema/          # NEW — cross-platform value types
  CinemaScreenPreset.swift     # enum: medium / large / imax / wall (+ physical metrics)
  CinemaEnvironment.swift      # enum: darkTheater (+ future nebula/deepSpace/orbit, declared not built)
  CinemaPreferences.swift      # struct Codable: screen, environment, seating, audio/subtitle prefs
  CinemaPreferencesStore.swift # actor; JSON in Application Support (mirrors LibraryPreferencesStore)

Aether/Sources/Cinema/                          # NEW — visionOS-only (#if os(visionOS))
  CinemaCoordinator.swift      # @MainActor @Observable: immersive-space lifecycle + live cinema state
  CinemaImmersiveView.swift    # RealityView: theater + screen entity + VideoPlayerComponent
  CinemaTheater.swift          # RealityKit scene builder for the Dark Theater (lights, floor, accents)
  CinemaScreenEntity.swift     # screen mesh/anchor + preset sizing + placement
  CinemaControlsView.swift     # the "separate control plane" attachment (transport + native pickers)
  CinemaEntrySequenceView.swift# logo fade → transition → space-ready handoff
  CinemaWatchButton.swift      # the "Watch in Cinema" CTA injected into DetailView (visionOS only)
```

Naming follows the repo's conventions: value-type descriptors and the store are
`Sendable`; views are SwiftUI; the coordinator is `@MainActor @Observable` like
`AppSession`, `SettingsViewModel`, `DownloadObserver`.

---

## 3. Required frameworks

All first-party, per Principle 1 (no third-party):

- **SwiftUI** — `App`/`Scene`, `ImmersiveSpace`, `WindowGroup`, `RealityView`,
  attachments, ornaments.
- **RealityKit** — theater entities, `VideoPlayerComponent` (or `VideoMaterial`
  fallback), `ModelEntity`, lighting (`ImageBasedLightComponent` /
  point/spot lights), `Entity` transforms.
- **AVFoundation** — the existing `AVPlayer`; `AVMediaSelectionGroup` /
  `AVPlayerItem.select(_:in:)` for the native-styled in-cinema audio/subtitle
  pickers (HLS renditions on transcode titles).
- **AVKit** — unchanged; still backs Window Mode. Not used inside the immersive
  space.
- **simd** — screen placement / seating offsets.
- **os.Logger** — reuse the `cz.zmrhal.aether` subsystem with a new
  `cinema` category for entry/exit + screen-bind diagnostics (token-free, same
  pattern as `playback`).

**Deliberately NOT used in V1:** PHASE / custom spatial audio DSP, RealityKit
particle systems, custom Metal shaders. The spec rules these out ("no reverb,
no simulated room acoustics, no floating particles"). Spatial audio comes from
`VideoPlayerComponent` anchoring sound to the screen entity natively.

---

## 4. Scene hierarchy

`AetherApp.body` today is a single `WindowGroup`. Proposed visionOS shape
(other platforms keep the single group):

```swift
var body: some Scene {
    WindowGroup(id: "main") {                 // existing RootTabView — Window Mode
        RootTabView(session: session)
            .environment(cinema)              // inject coordinator (visionOS)
    }
    #if os(visionOS)
    .windowStyle(.plain)

    ImmersiveSpace(id: CinemaCoordinator.spaceID) {   // Cinema Mode
        CinemaImmersiveView(session: session.playback, cinema: cinema)
    }
    .immersionStyle(
        selection: $cinema.immersionStyle,    // .full default, .progressive crown-blendable
        in: .progressive, .full
    )
    #endif
}
```

- **Window Mode** = the existing 2D app (`RootTabView`) running as a visionOS
  window. Browsing, Detail, and a standard windowed `AVPlayer` for "just play
  it" all live here. This is already ~working today (the app runs in iOS-compat
  mode on Vision Pro); V1 mostly makes it *feel* native (glass, depth on focus).
- **Cinema Mode** = the `ImmersiveSpace`. Exactly one environment in V1 (Dark
  Theater). Opened on demand, dismissed back to the window.
- **No volumetric window in V1.** A `WindowGroup(.volumetric)` is a clean future
  add for a "mini cinema preview" but is out of scope.

**Immersion style:** default `.full` (true blacks, IMAX feel, no passthrough),
with `.progressive` available so the Digital Crown can blend the room back in —
the same affordance Apple TV / Disney+ environments use on visionOS.

---

## 5. ImmersiveSpace strategy

- **One space id** (`"AetherCinema"`), one environment in V1. The `RealityView`
  switches its theater entity by `cinema.environment`; future environments
  (Nebula, Deep Space, Orbit) are new branches of one builder, not new spaces.
- **Lifecycle through the coordinator.** `CinemaCoordinator` holds
  `openImmersiveSpace` / `dismissImmersiveSpace` actions (captured from the
  SwiftUI environment) and serializes transitions so a double-tap can't open two
  spaces. State machine:

  ```
  .windowed → (Watch in Cinema) → .entering → .presenting → (Leave) → .exiting → .windowed
  ```

- **Single active space.** visionOS allows one immersive space at a time;
  the coordinator enforces it and is the single source of truth for "are we in
  the cinema."
- **Backgrounding / handoff:** on scene-phase change to background, pause via the
  existing view model (resume points already persist through `ResumeStore`); on
  return, the space restores to the same screen preset + position from
  `CinemaPreferences`.

---

## 6. Playback architecture (inside the cinema)

Reuse `PlayerStateViewModel` unchanged. The cinema view binds the vended player
to a RealityKit entity:

```swift
// CinemaImmersiveView (sketch)
RealityView { content, attachments in
    let screen = CinemaScreenEntity(preset: cinema.screenPreset)
    content.add(theater.makeEntity(for: cinema.environment))
    content.add(screen.entity)
    if let attachment = attachments.entity(for: "controls") {
        attachment.position = controlPlaneOffset(for: cinema.screenPreset) // closer to user
        content.add(attachment)
    }
} update: { content, _ in
    screen.apply(preset: cinema.screenPreset)        // live resize
} attachments: {
    Attachment(id: "controls") { CinemaControlsView(viewModel: viewModel) }
}
.task {
    await viewModel.open(item, source: source, startAt: startAt)  // SAME path as Window Mode
    if let player = viewModel.player {
        screen.bind(player: player)                  // VideoPlayerComponent(avPlayer:)
    }
}
```

**Screen rendering — `VideoPlayerComponent(avPlayer:)`.** We tried
`VideoMaterial` on a plane (to get a fully-custom control plane + exact metre
sizing), but on device it rendered the content as **scrambled blocks** — its
basic sampler doesn't handle the HDR / codec pipeline that `VideoPlayerComponent`
does. So the screen is `VideoPlayerComponent`: clean playback (incl. HDR),
correct aspect, native spatial audio, and a native transport. Size comes from a
**uniform `scale`** on the entity (it keeps the aspect, so uniform scaling is
undistorted); per-preset ratios read as the size steps. Consequence: the custom
control plane is **slim** (screen-size presets + Leave only) and the native
transport handles play / scrub / audio / subtitles — duplicating transport in
the custom panel is what produced the "double controls." Plex quality is set on
Detail before entering (not in-cinema).

**Spatial audio (spec §Spatial Audio):** `VideoPlayerComponent` anchors it to
the screen natively. No reverb, no room sim, no custom effects in V1.

**In-cinema audio/subtitle/quality pickers:** Window Mode delegates these to
AVKit's native picker, and the app's model is "primary selection happens on
Detail before play" (see AGENTS.md → *Player chrome*). The immersive space has no
AVKit picker, so the cinema control plane offers **native-styled SwiftUI
`Picker`s** that:
- **Audio / Subtitles:** drive `AVPlayerItem.select(_:in:)` against the live
  `AVMediaSelectionGroup`s — on-the-fly switching for HLS transcode titles,
  no re-resolve.
- **Quality:** changing the bitrate cap requires a fresh transcode session, so
  it re-runs the existing `viewModel.open(..., startAt: currentPosition)` path —
  the engine already rebuilds the URL; cinema just re-binds the new player to the
  screen. No engine change.

---

## 7. State management architecture

Four independent state owners, no cross-dependencies (mirrors the spec's "all
systems remain independent"):

| State | Owner | Isolation | Persisted? |
|---|---|---|---|
| **Playback** | `PlaybackSession` → `PlayerStateViewModel` | actor → `@MainActor` | resume points only (existing) |
| **Cinema session** (in/out, transition phase, immersion style) | `CinemaCoordinator` | `@MainActor @Observable` | no (ephemeral) |
| **Screen config** (preset, placement) | `CinemaCoordinator` (live) ← `CinemaPreferences` (defaults) | `@MainActor` ← actor store | yes |
| **User preferences** (preferred screen, environment, seating, audio/subtitle defaults) | `CinemaPreferencesStore` | actor | yes (JSON in App Support) |

`CinemaCoordinator` reads defaults from `CinemaPreferencesStore` on space-open
and writes back the last-used config on close — the foundation for **"Resume in
My Cinema."** It does *not* know about `MediaSource` or `PlaybackSession`
internals; it holds a reference to the shared `PlaybackSession` only to vend its
player to the screen entity.

`CinemaPreferences` injected via the SwiftUI environment, consistent with the
no-singletons rule.

---

## 8. UI wireframes

**Detail (visionOS) — adds one CTA, nothing else moves:**

```
┌───────────────────────────────────────────────────────────┐
│  ‹ Back                                          [glass]    │
│   ┌────────┐   BLADE RUNNER 2049                            │
│   │ poster │   2017 · 2h44m · 4K HDR · 5.1                  │
│   │        │   ┌──────────────┐  ┌────────────────────┐    │
│   └────────┘   │ ▶ Play        │  │ ◎ Watch in Cinema  │    │ ← new, primary on visionOS
│                └──────────────┘  └────────────────────┘    │
│   Audio ▾   Subtitles ▾   Quality ▾   ⤓ Download           │
└───────────────────────────────────────────────────────────┘
```

**Entry sequence (full immersion, ~2–3 s):**

```
   window dims        Aether mark          theater fades up        screen blooms in
   ░░░░░░░░░░    →    ╲A╱ (violet glow) →   · · soft indirect ·· →  ┌──────────┐
   (controls fade)    (logo, 0.8s)          (lights rise)          │  movie   │ → play
```

**Cinema Mode — Dark Theater, IMAX preset:**

```
              ╲                                                   ╱
               ╲          ┌───────────────────────────┐          ╱
                ╲         │                           │         ╱
   soft violet   ╲        │        T H E   F I L M     │        ╱   near-black
   wall accent    ╲       │      (screen = the hero)   │       ╱    walls, real
                   ╲      │                           │      ╱     OLED blacks
                    ╲     └───────────────────────────┘     ╱
                     ╲________________  dark floor  ________╱
                                   ▲ indirect uplight

          ┌─────────────────────────────────────────────┐   ← control plane,
          │  ⏮   ⏯   ⏭     0:42 ▕▓▓▓▓░░░░░░░▏ 2:44       │     ~0.4m closer to user,
          │  Audio ▾   CC ▾   Quality ▾   Screen ⤢   ⨉   │     auto-hides on inactivity
          └─────────────────────────────────────────────┘
```

**Screen-size switcher (immediately accessible — spec: used frequently):**

```
   Screen ⤢ →  ◯ Medium   ◯ Large   ● IMAX   ◯ Wall
                (live resize via RealityView update closure)
```

**Controls auto-hide:** appear on gaze-into-control-region, tap, or pause;
fade after inactivity (reuse the ~2.5 s window + reduce-motion handling already
proven in `PlayerView`). Video is never covered — controls live on a *closer*
plane, not over the image (spec §Playback Controls).

---

## 9. Development phases

Sliced so each lands independently and is verifiable on-device. One feature per
branch (AGENTS.md). All branch from `staging`.

| Phase | Deliverable | Verifiable when… |
|---|---|---|
| **C0 — Window Mode native pass** | visionOS runs `RootTabView` as a real visionOS window: glass materials, focus elevation/parallax on posters, ornament tab bar. No immersive code yet. | Browsing + windowed playback feel native on Vision Pro, not iOS-in-a-box. |
| **C1 — Immersive scaffold** | `ImmersiveSpace` + `CinemaCoordinator` + a *bare* screen (`VideoPlayerComponent`) in an empty space, driven by the existing `PlaybackSession`. "Watch in Cinema" opens it; playback works. | Same movie plays on a floating screen; engine untouched (diff proves it). |
| **C2 — Dark Theater** | `CinemaTheater` builder: near-black room, dark floor, soft indirect light, restrained violet accents. `.full`/`.progressive` immersion + crown blend. | The space reads as a screening room, not a void. |
| **C3 — Screen presets** | `CinemaScreenPreset` (Medium/Large/IMAX/Wall) + live resize + the always-accessible switcher. | Switching presets resizes the screen smoothly with audio anchored. |
| **C4 — Control plane** | `CinemaControlsView`: transport + scrubber + auto-hide + native-styled Audio/Subtitle (`AVMediaSelection`) and Quality (re-resolve) pickers. | All controls work without covering the video; tracks switch live. |
| **C5 — Entry / exit + branding** | `CinemaEntrySequenceView`: logo fade → transition → screen bloom; reverse on leave. Branding pass (black / indigo / violet / glass). | Entering feels like arriving at a destination, not opening a player. |
| **C6 — Personal Cinema** | `CinemaPreferences` + store; remember screen/environment/seating/audio/subtitle; "Resume in My Cinema." | Re-entering restores the exact prior setup. |
| **C7 — Polish** | Spatial-audio head-turn verification, performance (90 fps, hitch audit), reduce-motion, accessibility, on-device QA. | Holds 90 fps; passes a real-device review. |

Future environments (Nebula / Deep Space / Orbit) and Shared Cinema / Personas /
watch parties are **explicitly out of V1** — designed-for (one environment
builder, one space id, source-agnostic player) but not built (spec §Future
Roadmap).

---

## 10. Estimated implementation complexity

T-shirt sizes; "risk" = unknowns most likely to bite.

| Phase | Size | Primary risk |
|---|---|---|
| C0 Window native pass | **S–M** | Mostly styling; low risk. |
| C1 Immersive scaffold | **M** | First RealityKit + ImmersiveSpace wiring; `VideoPlayerComponent` ↔ `AVPlayer` lifecycle (binding the *vended* player, not creating a second one). |
| C2 Dark Theater | **M–L** | Art direction iteration; lighting that reads premium without assets. May want a baked USDZ environment + IBL — asset pipeline is the unknown. |
| C3 Screen presets | **S–M** | Live entity resize + keeping audio anchored across resize. |
| C4 Control plane | **M** | `AVMediaSelection` wiring for live track switch; attachment placement + gaze/auto-hide ergonomics. |
| C5 Entry/exit + branding | **M** | Sequencing `openImmersiveSpace` (async) against the logo fade so it never janks. |
| C6 Personal Cinema | **S–M** | Straightforward store; mirrors `LibraryPreferencesStore`. |
| C7 Polish | **M** | 90 fps under video + RealityKit; only fully testable on hardware. |

**Overall: a Large feature, ~7 thin phases.** The single biggest de-risking fact
is §0: the playback engine needs **zero** changes, so the hard, regression-prone
part of media playback is already done and tested. The genuine unknowns are all
in **art direction (C2)** and **on-device performance/ergonomics (C7)** — neither
of which can be fully judged in the simulator (AGENTS.md: "test on real hardware
before claiming done").

---

## Open questions / flags for you

1. **Branding tension — gold.** The spec says *avoid gold* for Cinema. The
   current brand (`Tokens.swift`) carries `accentGold` / `accentAmber` as the
   warm cinematic accent on hero surfaces. That's fine — gold is already
   documented as "secondary accent only," so Cinema simply uses the
   **black / indigo / violet / glass** subset and omits gold. No token change
   needed, just discipline in the cinema views. Confirm you're happy with that
   reading.
2. **Immersion default.** Recommend `.full` default with `.progressive` crown
   blend. Agree, or start `.progressive` (passthrough visible) for comfort?
3. **Asset strategy for Dark Theater (C2):** procedural RealityKit (no assets,
   fully in-code, easy to iterate) vs. a baked USDZ room + IBL (richer, needs an
   art pipeline). I'd start procedural and graduate to USDZ only if it doesn't
   read premium. OK?
4. **Roadmap placement.** This is bigger than 0.4 Premium UX (cross-platform
   polish) and orthogonal to 0.5 Distribution. Suggest a dedicated milestone —
   e.g. **`0.6 Vision Pro Cinema`** — added to `ROADMAP.md` *when* we start
   implementing (not now, since we're local-only). Want me to draft that
   ROADMAP entry as a separate step?

## Roadmap placement

Not yet a promise. When implementation starts, this doc becomes the living plan
for a new milestone and a one-line `ROADMAP.md` entry + `CHANGELOG [Unreleased]`
note land in the first implementation PR (AGENTS.md: docs change with code).
