# Project Context

Persistent project knowledge for every AI session working in the Aether repository.

## Product Vision

Aether is a premium Apple-native media platform for people who want one elegant place to watch and manage personal media across Apple devices.

The product goal is not to be a kitchen-sink media center. Aether should feel cinematic, fast, private, and unmistakably native to Apple's platforms.

## Platforms

- iOS
- iPadOS
- tvOS
- visionOS
- macOS

## Supported Sources

- Plex (multiple servers, multiple accounts)
- Jellyfin (multiple servers)
- Emby (multiple servers)
- Local Library
- SMB

All sources fan out into one merged `UnifiedLibrary` — source is an implementation
detail behind a title, not a separate tab or browsing mode. Netflix availability
is an optional metadata and discovery integration, not a playback source.

## Technology Stack

- SwiftUI
- Swift Concurrency
- Swift Testing
- AVPlayer / AVKit
- VLCKit
- libmpv on macOS
- RealityKit / Reality Composer Pro assets for visionOS cinema
- XcodeGen
- TMDb metadata

## Architecture Overview

- `Aether/` contains app-level SwiftUI views, navigation, and platform glue.
- `AetherCore/` contains shared models, media-source logic, playback, storage, downloads, and design-system primitives.
- The multiplatform `Aether` target serves iOS, iPadOS, tvOS, and visionOS.
- macOS has a dedicated native target, `AetherMac`, sharing `AetherCore`.
- Playback uses AVKit on Apple platforms and libmpv on macOS.
- Unified Library aggregates titles across sources so users browse media, not connectors.

For deeper detail, see `/docs/architecture/ARCHITECTURE.md` and `/docs/architecture/PLAYER_ENGINES.md`.

## Design Principles

- Apple-native
- Premium
- Cinematic
- Minimal chrome
- Typography-first hierarchy
- Privacy-first
- Platform-appropriate interaction

For the full visual language, see `/docs/ux/DESIGN_PRINCIPLES.md`.

## Active Features

- Unified Home / Library / Discover experience across every connected source
- Plex multi-server, multi-account support
- Jellyfin and Emby support, each with multiple servers
- Local Library (macOS and iOS-family)
- SMB browsing and playback
- Native playback with resume, watched sync, and continue watching
- Cross-device resume via media-server sync
- Downloads / offline playback
- visionOS Cinema Mode
- Ask Aether — on-device natural-language recommendations grounded in the user's own library
- Localization: English, Czech, Ukrainian
- Netflix availability badges and discovery integration

## Known Limitations

- Public TestFlight / release hardening is still ongoing work, not a fully closed loop.
- visionOS Cinema still has active polish around controls, ergonomics, and environment evolution.
- Some roadmap features are platform-asymmetric, especially where macOS uses a different player engine.
- Local Library is strongest on macOS; equivalent non-server workflows on iOS-family platforms are still limited.
- App Store / release readiness needs continuous validation as the product surface grows.

## Current Priorities

- Stabilize the `staging` branch (currently tracking 0.8.7)
- Public TestFlight readiness
- Playback reliability across platforms
- Unified Library polish
- visionOS Cinema Mode refinement
- macOS parity and release readiness

## Recommended Read Order

1. `/AGENTS.md`
2. `/docs/PROJECT_CONTEXT.md`
3. `/docs/CURRENT_SPRINT.md`
4. `/docs/ROADMAP.md`
5. `/CHANGELOG.md`
6. `/docs/product/PRODUCT_SPEC.md`
7. `/docs/architecture/ARCHITECTURE.md`
8. `/docs/ux/DESIGN_PRINCIPLES.md`
