# Current Sprint

AI-facing snapshot of the current working focus. Update this whenever staging priorities materially change.

## Current Release Train

- Branch baseline: `staging`
- Marketing version: `0.8.7` (0.8.5 "Eridanus" shipped to `main` 2026-06-28; 0.8.6 and the 0.8.7 train are staging-only so far)
- Recent shipped scope (0.8.6): Ask Aether — on-device natural-language recommendations grounded in the user's own library (#548), Search/Home/Library entry points
- Recent shipped scope (0.8.7, in progress on staging): macOS — Ask Aether replaces the classic Library search field; more compact, centered Discover hero banner; What's New sheet in macOS About
- Earlier shipped scope (0.8.5): multi-server — several Jellyfin/Emby servers + a 2nd Plex account, iOS + macOS (#518/#519/#520); Jellyfin Identify / RemoteSearch+Apply incl. shows (#511/#515); Jellyfin username+password sign-in (#509); Jellyfin resume via PlaybackInfo, fixes -1008 (#512); cinematic Discover hero (#517); detail hero dark-logo→text legibility (#516); library no-blank-on-empty-refresh (#510); Settings wordmark under tab bar (#514); server-side audio-language filter (#513)

## Sprint Goal

Close the gap between "feature-complete for internal use" and "confident enough for broader external testing and release preparation."

## Active Issues

- visionOS playback ergonomics, especially player controls and dismissal behavior
- Release hardening across App Store / TestFlight / Xcode Cloud workflows
- Platform parity gaps between iOS-family targets, tvOS, visionOS, and macOS
- Localized titles, search, and artwork language (#344, #345, #340)

## Features In Progress

- visionOS Cinema and playback polish
- macOS polish and release path improvements (Ask Aether, Discover banner — see Current Release Train)

## Immediate Priorities

- Keep `staging` stable and releasable
- Avoid regressions in playback, watched state, resume, and navigation
- Verify platform-specific interaction details before declaring UX changes done
- Keep docs, changelog, and release notes aligned with shipped behavior

## Guardrails

- Prefer finishing and stabilizing existing work over opening broad new surface area
- Treat playback regressions as high severity
- Treat platform interaction mismatches as product issues, not polish-only issues
- Update docs when product behavior or architecture meaningfully changes
