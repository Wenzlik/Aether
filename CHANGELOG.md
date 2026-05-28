# Changelog

All notable changes to Aether are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

- Initial repository bootstrap
- Verified `xcodegen generate` produces a clean project; relocated generated
  `Info.plist` and `Info-tvOS.plist` to `Aether/SupportingFiles/` so they're
  referenced via `INFOPLIST_FILE` only (not bundled as Resources)
- Excluded `.gitkeep` placeholders from the `Aether/Resources` resource phase
- DesignSystem: added `SectionHeader`, `BackdropImage`, `CachedAsyncImage`
- DesignSystem: `CardView` now supports artwork via `CachedAsyncImage`, lifts
  softly on tvOS focus, and renders a progress bar overlay
- Documented concrete token numbers (spacing, radii, motion, color,
  typography) in `docs/ux/DESIGN_PRINCIPLES.md`
