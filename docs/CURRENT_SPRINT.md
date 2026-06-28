# Current Sprint

AI-facing snapshot of the current working focus. Update this whenever staging priorities materially change.

## Current Release Train

- Branch baseline: `staging`
- Marketing version: `0.8.5` *(codename "Eridanus" → main 2026-06-28)*
- Recent shipped scope (0.8.5): multi-server — several Jellyfin/Emby servers + a 2nd Plex account, iOS + macOS (#518/#519/#520); Jellyfin Identify / RemoteSearch+Apply incl. shows (#511/#515); Jellyfin username+password sign-in (#509); Jellyfin resume via PlaybackInfo, fixes -1008 (#512); cinematic Discover hero (#517); detail hero dark-logo→text legibility (#516); library no-blank-on-empty-refresh (#510); Settings wordmark under tab bar (#514); server-side audio-language filter (#513)

## Sprint Goal

Close the gap between "feature-complete for internal use" and "confident enough for broader external testing and release preparation."

## Active Issues

- visionOS playback ergonomics, especially player controls and dismissal behavior
- Release hardening across App Store / TestFlight / Xcode Cloud workflows
- Platform parity gaps between iOS-family targets, tvOS, visionOS, and macOS
- Localized titles and artwork language (#344, #345, #340)
- SMB + MKV playback latency (#347, #213)

## Features In Progress

- visionOS Cinema and playback polish
- macOS polish and release path improvements
- Localization tail (#320)
- DetailViewModel refactor (#241)

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
