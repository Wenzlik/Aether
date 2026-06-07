# Aether Cinema — Reality Composer Pro content

This package holds the **Dark Theater cinema environment** for visionOS. It is
**not linked to the app as a Swift package** (RealityKit content can't build for
tvOS via SPM, and the app is multiplatform). Instead, the app bundles the
`.rkassets` folder directly as a resource:

```
Sources/RealityKitContent/RealityKitContent.rkassets/   ← author scenes here
```

`project.yml` adds that folder to the **Aether** target's resources, so
`realitytool` compiles it at the app's own deployment target (tvOS 26 satisfies
its ≥19 requirement). At runtime the app loads the scene by name from
`Bundle.main` (see `DarkTheaterView.loadAuthoredEnvironment`).

## The model: one scene, sized in code

There is a **single** authored scene — `AetherDarkTheater.usda` — used for every
screen-size preset. The preset (Medium/Large/IMAX/Wall) does **not** pick a
different scene; instead `DarkTheaterView` scales the authored `DockingRegion`
entity in code (`CinemaScreenPreset.relativeScale`), so:

- **Medium = the size you authored** (`relativeScale == 1.0`).
- Large / IMAX / Wall widen the docked screen from there.

This means you only ever author (and maintain) one room + one dock.

## What the scene must contain

Open **this package** in Reality Composer Pro (`File ▸ Open` →
`RealityKitContent`) and edit `AetherDarkTheater.usda`:

1. **One `DockingRegion`** (RCP: *Object ▸ Video Dock*) on an entity named
   **`Player`** (the app finds it by that name — see
   `DarkTheaterView.dockEntityName`). Position it at the front wall and size it
   for the **Medium** baseline; the larger presets scale up from there. This is
   what makes the video dock — there is no Swift API to create the region. If the
   `Player` entity is renamed or missing, the app still loads the scene at its
   authored size (the resize is skipped, not fatal).
2. **A reflective floor** + room art (walls, cove lighting) — already authored in
   the shipped scene. Anything you remove, the app does *not* redraw; the
   procedural fallback only runs when the whole asset fails to load.

> The procedural Dark Theater in `DarkTheaterView.makeEnvironment()` is the
> fallback if `AetherDarkTheater.usda` is missing/unloadable — the app always
> works. Validate dock size + reflections **on a real Vision Pro** (the
> Simulator misjudges docking, reflections, and scale).

## How the app uses it

- Settings ▸ Cinema lets the user pick a default screen size (persisted).
- "Watch in Cinema" opens the single `ImmersiveSpace` (`CinemaManager.spaceID`).
- `DarkTheaterView` loads `Entity(named: "AetherDarkTheater", in: .main)`, scales
  the `Player` dock for the chosen preset, and adds it; if the asset can't load
  it falls back to the procedural room.
