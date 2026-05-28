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

- **Black backgrounds**, especially on OLED. No off-black.
- **One accent**, used sparingly. A soft, slightly desaturated tone (current draft: a warm steel). The accent appears on focus rings, progress, key CTAs — nowhere else.
- **Type uses grayscale**, with high contrast for primary text and ~60–70% white for secondary.
- **Status colors** (error red, success green) are used only when status is the message. Never decorative.

Concrete colors are in `DesignSystem/Tokens`. Never hard-code a color in a view.

---

## Typography

- **System font** (SF Pro / SF Pro Display) throughout. No custom fonts.
- **Display weight** for hero titles. **Semibold** for section headings. **Regular** for body. **Medium** for metadata rows.
- **Dynamic Type** is honored on iOS. tvOS uses fixed couch-distance sizes (the system fixes those for us).
- **Line length** caps around 70 characters on iPad/tvOS. iOS reflows naturally.
- **Numerals** are tabular when they sit in a row that updates (timestamps, durations).

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

| Token | Description |
|-------|-------------|
| `Palette.background` | `Color.black` — real black, especially on OLED |
| `Palette.surface` | `Color(white: 0.08)` — for card skeletons, opaque chrome |
| `Palette.textPrimary` | `Color.white` |
| `Palette.textSecondary` | `Color.white.opacity(0.65)` — metadata rows |
| `Palette.textTertiary` | `Color.white.opacity(0.40)` — captions, hints |
| `Palette.accent` | `Color(red: 0.78, green: 0.78, blue: 0.86)` — focus rings, progress, key CTAs only |

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
