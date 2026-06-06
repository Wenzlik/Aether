# Aether Cinema — Reality Composer Pro content

This package holds the **per-screen-size cinema environments** for visionOS. It
is **not linked to the app as a Swift package** (RealityKit content can't build
for tvOS via SPM, and the app is multiplatform). Instead, the app bundles the
`.rkassets` folder directly as a resource:

```
Sources/RealityKitContent/RealityKitContent.rkassets/   ← author scenes here
```

`project.yml` adds that folder to the **Aether** target's resources, so
`realitytool` compiles it at the app's own deployment target (tvOS 26 satisfies
its ≥19 requirement). At runtime the app loads scenes by name from
`Bundle.main` (see `DarkTheaterView.loadAuthoredEnvironment`).

## What to author

Open **this package** in Reality Composer Pro (`File ▸ Open` →
`RealityKitContent`). Create **one scene per screen-size preset**, named
exactly (the app loads them by these names — see `CinemaScreenPreset.sceneName`):

| Scene name     | Preset | Target screen width |
|----------------|--------|---------------------|
| `CinemaMedium` | Medium | ~3 m                |
| `CinemaLarge`  | Large  | ~5 m                |
| `CinemaIMAX`   | IMAX   | ~8 m                |
| `CinemaWall`   | Wall   | ~12 m               |

Each scene should contain:

1. **A `DockingRegion`** (Reality Composer Pro: *Object ▸ Video Dock*) positioned
   at the front of the room and **sized to that preset's screen width**. This is
   what makes the docked video that size — there is no Swift API for it. The box
   is a fixed **2.4:1**; pick widths near real movie aspect ratios so a 16:9
   source doesn't letterbox oddly. (`CinemaScreenPreset.widthMetres` is the
   intended width per preset — tune on device.)
2. **A reflective floor** — a `Reflection_Specular` ShaderGraph material so the
   docked video reflects on the floor. (`Reflection_Diffuse` needs precomputed
   UVs baked for a fixed dock/floor and breaks if either moves — prefer
   `Reflection_Specular` for per-preset docks.)
3. Optional: the room art (walls, cove lighting, IBL probe) — or keep it minimal
   and let the procedural Dark Theater style guide it. Anything you don't author
   here, the app draws procedurally as the fallback.

## How the app uses it

- Settings ▸ Cinema lets the user pick a default screen size (persisted).
- "Watch in Cinema" opens that preset's `ImmersiveSpace` (`AetherApp.cinemaSpace`).
- `DarkTheaterView` tries `Entity(named: "<sceneName>", in: .main)`; if the scene
  isn't authored yet, it falls back to the procedural room (so the app always
  works, even with this `.rkassets` empty).

> Until you author the scenes, every preset opens the same procedural Dark
> Theater at the system-default dock size — the wiring is in place; the scenes
> are the remaining (asset) step. Validate dock widths + reflections **on a real
> Vision Pro** (the Simulator misjudges docking, reflections, and scale).

`Placeholder.usda` is just there so the empty `.rkassets` compiles — replace or
delete it once real scenes exist.
