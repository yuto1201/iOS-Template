# Tile kinds and how to build them

Every recipe below uses Goldie 0.3.1 as installed (see [config](config.md)). Put the
fields in `goldie/<locale>/goldie.config.ts`; relative image paths resolve against
the config file, so shared adopted images live in `goldie/assets/` and are referenced
as `../assets/<file>.png`. The iPhone tile is 1320×2868.

## Backgrounds

- Solid: `theme.background: "#E9EFF5"`.
- Gradient: `theme.background: "linear-gradient(160deg, #1B3B6F 0%, #4E8CCB 55%, #BFE3F2 100%)"`.
  Goldie parses `linear-gradient` with a `deg` or `to <side>` direction and color
  stops; it picks light or dark copy colors from the hex colors it finds.
- A per-scene `background` overrides the theme one.
- **Generated images under the copy need the render extension.** Goldie 0.3.1 draws
  image layers (`decorations`) after the headline, so a full-tile image hides it.
  Use image layers only for small pieces placed away from the copy (a `callout`, a
  badge); full-tile generated backgrounds arrive with the render extension (D-077).

## `device` — real screen with styling

Layouts: `classic` (copy above a centered device), `copy-below`, `hero` (large device
running off the bottom), `offset` (left copy, device bottom right), `tilt`,
`tilt-right`, `minimal` (no copy). Set `theme.layout` for the set or `layout` per
scene. Templates set the rhythm of a whole strip: `uniform`, `editorial`,
`showcase`, `magazine`, `storyboard`, `dynamic` (`theme.template`), or an array of
layout keys. A scene's own `layout` wins over the template.

## `pair` — two screens, or one screen in two states

`layout: "duo"` (a smaller screen behind on the left) or `"duo-tilt"`, with
`secondScene: "<scene id>"` naming the capture for the second device. For a state
comparison (day and night, before and after), use two real captures of the same
screen and say in the headline that it is a comparison.

## `panorama` — one picture across two tiles

`layout: "panorama"` (copy on the left, one large tilted device across the seam) or
`"panorama-duo"`. Goldie slices it into two PNGs, so it uses two store slots and
counts as two tiles in the rules.

## `continuous` — one background through every tile

Needs the render extension (D-077): one wide generated image runs under every tile,
and each tile shows its own slice. Until then, propose it only as a plan.

## `callout` — a magnified part of a real screen

Crop the region from the real capture without changing its pixels, scale it up, and
place it as an image layer beside the device in a layout that leaves room
(`offset`, `tilt-right`):

```sh
ffmpeg -i raw/home.png -vf "crop=600:420:360:900,scale=900:-1:flags=lanczos" goldie/assets/home-clock-callout.png
```

Image layers draw under the device, so keep the callout clear of the device. Record
the source capture's SHA-256 and the crop rectangle in `goldie/assets/provenance.json`.

## `scene` — the real device inside a generated setting

Needs the render extension (D-077): the generated setting is a full-tile image under
the copy and the real device. Until then, propose it only as a plan.

## `concept` — a generated image and headline, no device

Needs the render extension from D-077's follow-up Issue; until it exists, propose
this kind only as a plan and say it cannot be rendered yet. Place it after the first
three tiles, at most twice and in no more than a third of the set.

## iPad

iPad 13-inch tiles (2064×2752, no bezel) need the same render extension. Until then,
iPad stays on the repository capture path and is never stretched from iPhone.
