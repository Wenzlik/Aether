# Aether — Design Principles

Aether's visual language is **cinematic, calm, and Apple-native**. It borrows from where the best teams are going, then gets out of the way.

This document is what we measure design PRs against. If a screen breaks one of these rules, we either revise the screen or update this file with a documented reason.

---

## Inspiration

- **Apple TV app** — focus behavior, type-led layouts, restraint.
- **Infuse** — full-bleed artwork, cinematic detail screens.
- **Modern Plex** (post-redesign) — generous spacing, calmer chrome.
- **visionOS** — soft depth, materials, no hard cards.
- **Liquid Glass direction** — translucency, depth, layered surfaces that feel physical.

We are **not** copying any of these. We are choosing the same direction they chose.

---

## First principles

1. **Cinematic artwork is the loudest thing on screen.** UI defers to it.
2. **Typography-first hierarchy.** Type weight and size carry meaning before color does.
3. **Minimal chrome.** Show what's needed, hide what isn't, reveal on intent.
4. **Restrained color.** Mostly grayscale, a small accent palette, real OLED blacks.
5. **Soft depth.** Translucent materials, subtle shadows, no hard rectangles.
6. **Calm interaction model.** Springs over snaps, transitions over cuts, skeletons over spinners.
7. **Immersive browsing.** Library feels like flipping through a book of posters, not scrolling a list.
8. **Elegant loading and empty states.** First-run, offline, no-results — designed deliberately, not stubbed.
9. **Premium tvOS focus.** Every focusable element has an intentional focused state. Cards lift; type does not reflow.

---

## Cards

A "card" is anything with artwork — a movie poster, an episode thumbnail, a continue-watching tile.

- **Aspect ratios are real.** 2:3 for posters, 16:9 for episodes/stills, 1:1 for music. No squishing.
- **No outlines.** Cards are defined by their artwork, not by a stroke.
- **Corner radius** is consistent and platform-appropriate (~12pt iOS, ~16pt tvOS — see `DesignSystem/Tokens`).
- **Soft lift on focus/hover.** A subtle scale (~1.06) plus a soft shadow. No 3D parallax unless you can defend it.
- **Titles below the card** in a smaller weight; only when the card needs it. Continue-watching tiles include progress.
- **Loading state:** soft skeleton with the right aspect ratio. Never a colored placeholder rectangle.

---

## Overlays

Overlays are anything that appears on top of content — player chrome, modals, search.

- **Materials, not solids.** `.regularMaterial` / `.thinMaterial` on iOS, comparable on tvOS.
- **Fade in, fade out.** Never slide a solid sheet over content.
- **Auto-hide chrome** during playback after ~2s of no interaction. Reveal on touch/remote.
- **Respect safe area** without exception.
- **One overlay at a time.** No nested sheets. No alert-over-modal-over-popover.

---

## Spacing

Aether breathes.

- **Outer padding** is generous — at least system "large" on iOS, more on tvOS.
- **Inter-card gaps** match the visual weight of the cards. Posters get 16pt; episodes get 12pt.
- **Vertical rhythm** comes from type, not from explicit dividers. Dividers are nearly absent.
- **Section headings** sit alone in a row, with real space above. Never visually crammed.

Concrete tokens live in `AetherCore/DesignSystem/Tokens.swift`. Don't hard-code spacing in views; pull from the tokens.

---

## Transitions

Motion serves orientation, not decoration.

- **Library → Detail:** the focused card hero-transitions to the detail backdrop area.
- **Detail → Player:** crossfade through black, briefly. The player feels like it dims the room.
- **Sheet presentations:** slide up with a spring; no bounce.
- **Tab changes (iOS):** crossfade content; do not slide horizontally.
- **Focus shifts (tvOS):** spring-eased, fast enough to feel responsive, slow enough to read.

Durations live in `DesignSystem/Motion`. Defaults: 250ms for content, 350ms for hero, 180ms for focus.

---

## Motion

- **Springs, not curves**, for state changes. `.spring(response: 0.4, dampingFraction: 0.85)` as the default.
- **No bouncy excess.** A subtle settle is fine; a Disney bounce is not.
- **No spinners** where a skeleton or a progressive load would do.
- **Reduce motion** is honored. When the user asks for less motion, all hero and scale effects collapse to crossfades.

---

## Player controls

The player is where Aether spends the most polish budget.

- **Chrome fades** after ~2s of no interaction.
- **Big timeline on scrub.** When the user grabs the timeline, the timeline grows; thumbnails appear above it.
- **Big remaining-time numerals.** Time is a feature.
- **Subtitle and audio pickers** are full-bleed sheets, not nested menus.
- **Skip ± 10s** is gesture-driven on iOS (double-tap left/right) and remote-driven on tvOS.
- **AirPlay / PiP** buttons are always visible on iOS; in the corner, intentional.
- **No persistent buffer spinner.** Buffer state is shown subtly inside the timeline.

---

## Color

Aether's identity is **personal cinema**: a premium **blue** brand over a layered near-black base. Calm and atmospheric, never neon — and explicitly *not* Plex orange / Netflix red. *(0.6.0 refresh — the brand moved off violet; see [`docs/next-steps/ux-refresh-060.md`](../next-steps/ux-refresh-060.md).)*

- **Layered dark backgrounds** — a three-stop gradient (`#0B0D12` top → `#111827` mid → `#0A0A0F` bottom) with two faint brand blooms (bright-blue upper-left, subtle-purple upper-right) at 6–8 % over the base. Exposed as `AetherDesign.Gradients.background` and applied on every screen via the shared `aetherScreenBackground()` modifier so navigating never shows a background shift; it reads as depth, not wallpaper. Surfaces are zinc (`#18181B` / elevated `#27272A`). Background, surfaces, and separator resolve through `Color(light:dark:)` so the same tokens carry adaptive Light variants for the **Appearance** picker (System / Dark / Light) via `AppearancePreferenceStore`. Accent + semantic statuses stay single-value across modes. (Full-screen video keeps a pure-black background — nothing competes with the picture.)
- **Aether Blue** `#6A8BFF` is the primary accent — focus, selection, primary action, links, section accents. **`accentBright` `#5B7CFF`** is the brightened sibling (focus glow, progress fill) and **`accentIndigo` `#4C63E0`** the gradient depth partner (`Gradients.aurora` / `progress`). Accent appears on focus glow, progress, selected tracks, key CTAs — nowhere decorative. Re-pointing `Palette.accent` from violet to blue re-skins every interactive surface at once.
- **Subtle purple** `accentSecondary #9B7EBF` is the **secondary** accent only — muted/planned status, the secondary background bloom. Never primary interactive state. **Aether Gold** `#F5B524` / **Amber** `#F59E0B` are **brand-mark only** — the warm partner baked into the `AetherBrandMark` lockup + the `cinematic` gradient. **Never for selection, focus, or interactive primary actions.**
- **Type uses grayscale** — primary `#FAFAFA`, secondary `#A1A1AA`, tertiary `#71717A`.
- **Status colors** — success `#22C55E`, warning `#F97316` (orange-red, distinct from brand gold), error `#EF4444` — used only when status *is* the message, never decorative.
- **Focus** uses scale + a soft blue glow (`premiumFocus` — lift + `focusGlow #5B7CFF` shadow). **Never thick white borders or accent-tinted boxes.**

Concrete colors, gradients, and materials are in `DesignSystem/Tokens` (`AetherDesign.Palette` / `.Gradients` / `.Materials`, authored from hex via `Color(hex:)`). Never hard-code a color in a view.

---

## Typography

- **System font** (SF Pro / SF Pro Display) throughout. No custom fonts.
- **Display weight** for hero titles. **Semibold** for section headings. **Regular** for body. **Medium** for metadata rows.
- **Dynamic Type** is honored on iOS. tvOS uses fixed couch-distance sizes (the system fixes those for us).
- **Line length** caps around 70 characters on iPad/tvOS. iOS reflows naturally.
- **Numerals** are tabular when they sit in a row that updates (timestamps, durations).

---

## Navigation pattern

Aether uses **native top navigation** (`RootTabView` → SwiftUI `TabView`), not a custom shell. The system renders it as the **tvOS 26 top tab bar**, the **bottom bar on iOS / iPadOS**, and the **ornament on visionOS** — one structure, no per-platform layout code, no sidebar. This is the Apple-native pattern (Apple TV / Music / Photos on tvOS).

Four tabs, in order: **Home / Library / (Storage on iOS, iPadOS, visionOS | Discover on tvOS) / Settings**.

- **Home** — cinematic, content-first. A **branded header** sits above the rails: a centred `AetherWordmark(.large)` with an `AetherSearchField` beneath it. Below: **Continue Watching, then Featured, then a rail per library** — active content takes priority over discovery (same pattern Apple TV / Netflix / Disney+ use). Signed-out it shows the **Welcome** hero (wordmark-led, with a CTA) instead of the rails. The branded header is only drawn on the rails and during search — loading / error / welcome / library-empty states own their own full-screen layout and would compete with a duplicate brand mark.
- **Library** — branded browse hub. Same branded header pattern as Home (centred `AetherWordmark(.large)` + `AetherSearchField`), then an optional `Downloaded` rail (cross-source completed downloads, only when there are any), a Continue Watching rail (cross-library), a Recently Added rail (round-robin merge across libraries), and a section per library — title with inline count `"Movies (1,234)"`, horizontal poster rail, `See all` link that pushes the full `LibraryView` grid.
- **Storage** (iOS / iPadOS / visionOS) — the download manager. Total downloaded bytes + device free space, a per-source breakdown, an **In Progress** section (queued / downloading / paused / failed with state-specific Pause / Resume / Cancel / Retry actions), a **Downloaded** section with per-item Delete and a destructive Clear All. Tapping any row pushes `DetailView` — the offline-playback override in `PlaybackSession` then picks the local file.
- **Discover** (tvOS only) — tvOS-exclusive content-discovery surface that takes Storage's slot, because downloads make no sense on a lean-back persistent-network surface. Three rails: a single random **hero pick** (16:9 backdrop, randomly drawn from all libraries each build), **Random Picks** (12 shuffled titles), and **Recently Added** (round-robin interleave of each library's newest items). Builds via `DiscoverFeedBuilder` on top of the existing `MediaSource` APIs — no new endpoints. Picks re-shuffle per build; cached per session.
- **Settings** — a full-screen destination of grouped focusable cards (no longer a sheet). Opens straight into the centred `AetherWordmark(.large)` and content — the "Settings" page title and "Manage your media sources and playback." subtitle were dropped because the selected tab in the bar already says where the user is. Sections: **Account**, **Sources**, **Playback** (default Quality / Audio Language / Subtitle Language, each opening a sheet picker driven by `PlaybackPreferencesStore`), **Appearance** (System / Dark / Light, driven by `AppearancePreferenceStore` and applied via `.preferredColorScheme(_:)` at the app root), **About** (compact Version + Build row that expands a cumulative "What's New" bullet list on iOS / iPadOS / visionOS; on tvOS the expand pattern flips to a side-by-side layout — version left, bullets always-on right — because vertical scroll-off hides expanded disclosure content on the leanback surface).

Search uses `AetherSearchField` rather than the system `.searchable` modifier on Home and Library so the brand mark gets the top of the screen back — `.searchable` insists on placing its bar above any scroll content. The `@State searchQuery` binding still drives the same swap to `MediaSearchResults`; only the field's render position changed.

Each content tab (Home / Library / Storage / Discover) owns its own `NavigationStack`; the shared `mediaNavigationDestinations` modifier registers the `MediaItem → DetailView` and `Library → LibraryView` pushes once so every stack stays identical (and DetailView's playback pickers always see the same `PlaybackPreferencesStore` for default-track seeding).

Rules that follow from this:

- **No custom navigation chrome.** No bottom dock, no top capsule, no header account/gear icons — the system tab bar and the Settings tab own all of it. Account status surfaces inside Settings.
- **Focus is native.** Pressing up from the top of content reaches the tab bar via the system focus engine — no `.defaultFocus` hacks, no pinned headers fighting scroll.
- **Adding a fifth tab** is a deliberate design discussion — four is the budget.
- **Settings → Accounts & Sources uses source tiles, not a list.** A flat settings list wastes the 10-foot canvas (full-bleed rows leave the centre empty) and promotes destructive actions to the index. Connected sources are large focusable **tiles** (logo + name + server + an `Active` badge) in a two-column grid; not-connected ones are lighter **Add Source** tiles that start sign-in directly. Per-source management (set active, manage servers, SMB folders, and **Sign Out** behind a confirmation) lives in a pushed detail screen — never on the index. (`SourceTilesView`.) On iOS/iPadOS the list stays but splits into **Connected Sources** + **Add Source**, with Sign Out confirmed.

### macOS navigation

macOS is **not** the shared `RootTabView`. The Mac app is its own target (`AetherMac`), an Infuse-style **single window**: a `NavigationSplitView` **sidebar** (Home / Discover / Library / Search / Settings) plus an inline libmpv player that *swaps in over the window* when you play something. The sidebar is the Mac-native idiom — we do **not** force the iOS tab bar onto the Mac, and we do **not** convert the sidebar into a tab bar when it collapses (the iPad "collapse → slide-over" model is not the Mac model either).

- **The menu bar is always-available navigation.** A **View** menu lists every section with **⌘1…⌘5**, driven by the same `MacSession.section` the sidebar binds to. This works regardless of sidebar state, so **collapsing the sidebar never strands the user** — there is always another way to switch sections. (`AetherMacApp.commands` → `SectionCommands`.)
- **The system owns the titlebar / traffic-light zone.** No app-owned control sits in the window's top-leading corner over the traffic lights. The brand wordmark + sidebar toggle ride in a **leading titlebar accessory** (placed *after* the traffic lights by AppKit, never over them) and are **stripped during playback** so nothing floats over full-bleed video (`LibraryTitlebar` / `PlayerTitlebar`).
- **The active section is always identified** by the highlighted sidebar row, the detail pane's navigation title, and the View-menu checkmark.
- **Settings opens in the window's detail pane** (a sidebar section), separate from the native **Settings…** window (⌘,). Both exist; the in-window pane is the browsing-flow surface.

---

## Component naming

Every reusable view primitive in `AetherCore/DesignSystem/` shares the `Aether*` prefix:

- **`AetherCard`** + factories `.poster` (2:3) / `.hero` (16:9 with optional subtitle) / `.episode` (16:9 with optional progress overlay)
- **`AetherSectionHeader`** — title row above every horizontal rail
- **`AetherButton`** — three roles (`.primary` / `.secondary` / `.destructive`), one shape, one focus motion
- **`AetherEmptyState`** — designed hero glyph + title + body + optional CTA
- **`AetherLoadingState`** — skeleton rails (`.rails(count:)`) or inline pulse
- **`AetherErrorState`** — same shape as empty state, with a required retry
- **`AetherSettingsRow`** + **`AetherSettingsSection`** — settings list primitives; rows take a `value:`, an `actionRole:`, or a colour-coded `status:`
- **`AetherStatus`** — the colour-coded status value (`Available` green / `Not connected` red / `Planned` grey) shown on the trailing edge of settings + source rows
- **`AetherSelectionRow`** — focusable single-choice row (leading checkmark) used inside the Detail bottom-sheet pickers
- **`AetherDisclosureRow`** — label + current value + chevron; the iOS-native "current choice with more behind a tap" pattern. Used on Detail for Audio / Subtitles / Quality and on Settings for Default Quality / Audio Language / Subtitle Language / Appearance
- **`AetherSearchField`** — inline search capsule (magnifying-glass + placeholder + clear button). Used on Home and Library above the rails; replaces the system `.searchable` modifier because that one insists on placing its bar at the very top of the screen, which fights the brief that the brand mark gets that slot
- **`aetherFocusRow()`** — the standard tvOS focus lift (elevated fill + small scale + soft shadow) for list-style rows; native focus only, no borders

And the brand identity component (in the **app target**, not `AetherCore` — it carries an app-bundled image asset and isn't reusable outside this project):

- **`AetherWordmark`** — the brand mark lockup (icon + "AETHER" wordmark + under-mark glow line) baked into a single transparent PNG (`AetherBrandMark@3x`). Three variants (`.small` / `.medium` / `.large` → 22 / 36 / 60 pt tall; width follows the artwork's ~3:1 aspect), an optional `tagline:` parameter that stacks beneath the lockup. The view simply renders the artwork — no runtime `Text` composition, no per-letter gradients, no rounded-rectangle clip — so the lockup's colour and proportion stay designer-controlled. Used at the top of Home, Library, Settings, the Welcome hero, and Plex / Jellyfin sign-in / discovery sheets. Don't put it in every nav bar — over-application dilutes the mark.

If a view needs an "ad-hoc" empty / loading / error / selection surface, it's almost certainly missing one of these. Extend the primitive before reaching for a one-off.

### Track selection

Audio, subtitle, and quality selection live on **Detail**, before playback — the user should know exactly what will play before pressing Play. The Detail screen shows three `AetherDisclosureRow`s under one **Playback** section (`Audio · English · EAC3 5.1 ›` / `Subtitles · Off ›` / `Quality · Original · Direct Play ›`). Tapping a row opens a half-height bottom sheet (`presentationDetents([.medium, .large])`) containing the `AetherSelectionRow` list. Subtitles always include an **Off** row. The Quality row carries the projected playback mode inline for the Original choice (*Direct Play* / *Direct Stream* / *Transcode*) so the user knows what's about to happen before pressing Play.

The player itself carries **no track-switching API** — both `PlaybackSession.selectAudioTrack` and the in-player audio / subtitle pickers were removed; the player is no longer responsible for configuring streams. To change a track mid-watch, the user returns to Detail.

**`PlaybackPreferencesStore` seeds the pickers**. The user's Settings → Playback defaults (`defaultQuality`, `defaultAudioLanguage`, `defaultSubtitleLanguage`) are read inside `DetailView.hydrateForPlayback`: after the source hydrates the item, `applyingPreferences(to:)` matches the audio / subtitle preference against the actual tracks on the title (case-insensitive BCP-47 match) and pre-selects when a track exists, otherwise lets the source default stand. Quality is always applied because every option is valid on every title. The user's per-title picker tap still wins for that session — defaults are the seed, not a lock.

---

## Settings language

Settings is calm and factual, not marketing. Phrases:

- **"Plex / Connected as <name>"** — not *"Manage your Plex account"*.
- **"Sign Out of Plex"** — not *"Disconnect"* and not *"Log out"*. Capitalised, destructive role.
- **"Planned"** — exactly that, not *"Coming soon"*, *"Not available yet"*, or *"In development"*. Used uniformly for Synology, transcoding, offline downloads, anywhere a row references a future capability. Reads calmer and more deliberate than "Coming soon" — a status the team owns, not a promise the user is waiting on.
- **"Direct Play / Available"** — facts about the current playback path, not a promise.

The sign-out action is the **only destructive surface** in Settings. After tapping it, the user lands back on the Home welcome state — never on an error and never on a stale signed-in shell.

---

## visionOS-first considerations

Even before the visionOS app is feature-complete, every shared screen is designed so spatial-context use feels right:

- **Larger focus targets.** All `AetherButton`s pad to `l`/`s`; tap targets are never smaller than ~44pt.
- **Comfortable spacing.** Sections breathe with `xl`+ between them; never visually crammed at iPhone density.
- **Readable type.** Hero titles use Display weight; metadata rows stay at `metadata` (medium subheadline) so type holds at viewing distance.
- **Reduced density.** Posters and hero cards size up on tvOS — and the same scale will read on Vision Pro. Don't ship iOS density for couch / spatial contexts.
- **Calm motion.** Springs and crossfades, never slam-cuts. `Motion.focus` is short and gentle on purpose.
- **Minimal chrome.** Background is real black; surfaces use materials; only the active accent earns color.
- **Strong artwork hierarchy.** Backdrop is the first thing on Detail; type sits over it, not below it.

A spatial-native experience (ornaments, glass volumes, immersive player) is a separate future milestone. The base above is what every shared SwiftUI surface ships today.

---

## Empty states

Every empty state is designed. We do not ship "No items."

- **Library empty (no sources):** a soft illustration-light hero, a single CTA ("Add a source"), one short sentence.
- **Library empty (source connected, nothing in it):** a friendlier tone — "Nothing in this library yet."
- **Search empty (no query yet):** suggestion chips for recent, on-deck, new.
- **Search empty (query, no results):** "No matches in your library." No third-party fallback.
- **Offline (nothing downloaded):** "Travel mode is empty." with a CTA back to the library.

---

## Offline indicators

The user must always know whether they are playing local or remote.

- **A small offline glyph** appears in the player chrome and on detail screens when the source for the current title is local.
- **Library cards** show a discreet downloaded badge in the corner.
- **The settings → storage screen** shows the disk budget visually — a single bar, with the per-title slices labeled by size.

Never use a "no internet" *error* state where an "offline mode" *informational* state will do.

---

## tvOS focus behavior

Focus is the platform's UX. Get it right.

- **Every focusable thing has a focused state.** Not just a system-default ring.
- **Focused cards lift** (`~1.06` scale + soft shadow). They do not zoom violently.
- **Type does not reflow** when an item is focused. Reserving the space avoids layout jitter.
- **Focus sections** are used to keep horizontal rails feeling like rails — moving down from a rail goes to the next rail's leading item, not to wherever your last X-position was.
- **No tap gestures** as a substitute for focus. The Siri Remote is the cursor.
- **Top shelf** is stubbed until we have real content.

---

## Accessibility

A premium Apple-platform app is accessible by default.

- **VoiceOver:** every interactive element has a label; decorative elements are hidden.
- **Dynamic Type:** honored on iOS / iPadOS where it applies.
- **Reduce Motion:** honored — all hero transitions become crossfades, all spring scales collapse.
- **Sufficient contrast** against artwork — overlays use materials so type stays readable even on busy backdrops.
- **Focus reachability** on tvOS: nothing focusable is unreachable with the remote.

---

## Concrete tokens

The adjectives above (generous, restrained, soft) map to real numbers in `AetherCore/DesignSystem/Tokens.swift`. Pull from `AetherDesign.*` — never hard-code a value in a view.

### Spacing

| Token | Points | Where it's used |
|-------|--------|-----------------|
| `Spacing.xxs` | 4  | tight stacks, inline metadata |
| `Spacing.xs`  | 8  | card title → artwork gap |
| `Spacing.s`   | 12 | secondary insets |
| `Spacing.m`   | 16 | inter-card gaps on posters; outer iOS padding |
| `Spacing.l`   | 24 | section outer padding, default screen edges |
| `Spacing.xl`  | 32 | gap between major sections |
| `Spacing.xxl` | 48 | header → first content row on Home |

### Radii

| Token | Points | Where |
|-------|--------|-------|
| `Radius.card`   | 12 | iOS poster / episode cards |
| `Radius.cardTV` | 16 | tvOS cards (slightly softer for couch distance) |
| `Radius.sheet`  | 20 | bottom sheets, modal containers |

### Motion (durations)

| Token | Animation | Used for |
|-------|-----------|----------|
| `Motion.content` | `easeInOut(0.25)` | tab/content swaps, cache refreshes |
| `Motion.hero`    | `easeInOut(0.35)` | Library → Detail hero, Detail → Player crossfade |
| `Motion.focus`   | `spring(response: 0.18, damping: 0.85)` | tvOS card lift on focus |
| `Motion.card`    | `spring(response: 0.40, damping: 0.85)` | drawer / sheet appearance, list reorders |

All of these collapse to instant cuts when **Reduce Motion** is enabled.

### Color

| Token | Value | Description |
|-------|-------|-------------|
| `Palette.accent` | `#6A8BFF` | **Aether Blue** — primary: focus, selection, primary action, links |
| `Palette.accentBright` | `#5B7CFF` | brightened blue — focus glow, progress fill, active |
| `Palette.accentIndigo` | `#4C63E0` | gradient depth partner (dark stop of aurora/progress) |
| `Palette.accentSecondary` | `#9B7EBF` | **subtle purple** — secondary only (muted/planned status, secondary bloom) |
| `Palette.accentGold` | `#F5B524` | **Aether Gold** — brand-mark / `cinematic` gradient only; never interactive |
| `Palette.accentAmber` | `#F59E0B` | warm anchor of the `cinematic` gradient only |
| `Palette.background` | `#0B0D12` | top stop of the layered base |
| `Palette.backgroundMid` | `#111827` | mid (charcoal-blue) depth stop |
| `Palette.backgroundBottom` | `#0A0A0F` | bottom near-black stop |
| `Palette.surface` | `#18181B` | cards, chrome |
| `Palette.surfaceElevated` | `#27272A` | focused rows, raised surfaces |
| `Palette.textPrimary` | `#FAFAFA` | primary text |
| `Palette.textSecondary` | `#A1A1AA` | metadata rows |
| `Palette.textTertiary` | `#71717A` | captions, hints |
| `Palette.success` | `#22C55E` | "Available" / "Connected" status |
| `Palette.warning` | `#F97316` | warnings (orange-red, distinct from brand gold) |
| `Palette.error` | `#EF4444` | "Not connected" status, destructive |
| `Palette.focusGlow` | = `accentBright` | the blue focus glow |

Gradients: `Gradients.aurora` (indigo→bright-blue sweep, primary CTA + featured), `Gradients.progress` (Continue Watching strip / scrubbers), `Gradients.backgroundBase` (the three-stop layered base) + `Gradients.background` (base + faint blue/purple blooms — the whole-screen atmosphere, via `aetherScreenBackground()`), `Gradients.heroBloom` (radial blue behind the Welcome hero), `Gradients.cinematic` (blue → blue → gold — brand mark only; once per screen). Materials: `Materials.card` (`.ultraThinMaterial`) / `Materials.chrome` (`.regularMaterial`). Shared modifiers: `aetherScreenBackground()`, `aetherHeroScrim()`, `premiumFocus()` (`AetherModifiers.swift`).

### Typography

| Token | System style + weight | Used for |
|-------|-----------------------|----------|
| `Typography.heroTitle` | `.largeTitle` / bold | Detail hero, Home hero |
| `Typography.sectionTitle` | `.title2` / semibold | Row headings on Home |
| `Typography.cardTitle` | `.headline` / medium | Card titles below artwork |
| `Typography.body` | `.body` / regular | Long-form text |
| `Typography.metadata` | `.subheadline` / medium | Metadata rows, accessory labels |
| `Typography.caption` | `.caption` / regular | Hints, badges, fine print |

---

## Anti-patterns to refuse

If you find yourself doing one of these, stop and reconsider.

- A spinning activity indicator where a skeleton would do.
- An outline around a card.
- A second accent color "for variety."
- A custom font.
- A modal that contains another modal.
- Tap-target hacks on tvOS instead of using focus correctly.
- A loading state that throws the whole screen away (use partial reveals).
- A "fun" sound effect or haptic that wasn't designed by the system.

When you're not sure: ask yourself, *"would the Apple TV app do this?"* If no — make sure you have a reason.
