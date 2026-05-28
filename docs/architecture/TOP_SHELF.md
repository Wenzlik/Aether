# Top Shelf — design note

> **Status:** intentionally stubbed until 0.2 ships real media sources.

The Apple TV "Top Shelf" is the wide artwork carousel that appears above an installed app's icon on the Home screen. When the user focuses Aether on the Home screen, this is the first impression — before the app even launches.

Aether's `AGENTS.md` is explicit:

> Top shelf is stubbed until we have real content. Stub it explicitly until then.

This file is the stub. We know we need one; we know what it should do; we're not building it yet.

---

## Why we're not building it in 0.1

The Top Shelf needs real artwork and real titles. In 0.1 the library is a mock fixture without poster or backdrop URLs — every card is a skeleton. A Top Shelf full of skeletons is worse than no Top Shelf at all (it looks broken).

The minute artwork starts flowing — Plex `posterURL` / Synology backdrop URLs in 0.2 — the Top Shelf becomes worth building.

---

## What it will look like

A Top Shelf extension is a separate target in the Xcode project, embedded in the main Aether-tvOS app. It ships a `TVTopShelfContentProvider` (modern API) or a `TVApplicationController` (legacy) that returns one of:

- **Inset content** — a single hero with a CTA. Used when the user has one obvious "next thing" (e.g., a half-watched episode from Continue Watching).
- **Sectioned content** — typed rails (`recentlyAdded`, `top`, etc). Used when there's a coherent set to show off (Continue Watching, Featured, On Deck from Plex).

Aether will start with **sectioned content** and pick one of:

1. **Continue Watching** — the user's resume points, intersected with available sources.
2. **Featured** — the curated list from the active source (mock today, Plex/Synology later).

Either is fine; both depend on `HomeFeedBuilder` already producing the data the running app uses, so the Top Shelf provider can call into `AetherCore` exactly the same way `HomeView` does.

---

## What lands when this stops being a stub

When we're ready to ship a real Top Shelf, the work is:

1. Add a new XcodeGen target in `project.yml`:
   - `Aether-TopShelf` — `bundle.extension`, `TopShelf` extension point, tvOS only.
   - Bundle ID: `cz.zmrhal.aether.tvos.topshelf`.
   - Depends on `AetherCore`.
2. New folder: `Aether-TopShelf/Sources/`.
3. Implement `TVTopShelfContentProvider`:
   - Build a `HomeFeed` via `HomeFeedBuilder` against the active source.
   - Map `featured` (or `continueWatching`) to `TVTopShelfSectionedItem` instances.
   - Wire `displayAction` and `playAction` to deep links into the main app.
4. App-side: handle the deep link URLs (we don't have any yet — picking a `aether://` scheme will be its own micro-PR).
5. App Store screenshots that include the Top Shelf.

---

## What the stub currently does

Nothing. There's no extension target, no provider, no entitlement. The Top Shelf area above Aether's icon will show the default app artwork until this lands.

The point of this file is so that:
- A new contributor sees the gap and knows it's intentional.
- The architecture review doesn't waste cycles "discovering" we lack a Top Shelf.
- The first PR that adds it has a written design to push against.
