# Tile kinds and how to build them

Every recipe below uses Goldie 0.3.1 as installed (see [config](config.md)). Put the
fields in `goldie/<locale>/goldie.config.ts`; relative image paths resolve against
the config file, so shared adopted images live in `goldie/assets/` and are referenced
as `../assets/<file>.png`. The iPhone tile is 1206×2622 (D-079).

## Backgrounds

- Solid: `theme.background: "#E9EFF5"`.
- Gradient: `theme.background: "linear-gradient(160deg, #1B3B6F 0%, #4E8CCB 55%, #BFE3F2 100%)"`.
  Goldie parses `linear-gradient` with a `deg` or `to <side>` direction and color
  stops; it picks light or dark copy colors from the hex colors it finds.
- A per-scene `background` overrides the theme one.
- Generated image: `backgroundImage: "../assets/rain-sky.png"` on a scene or on
  `theme`, rendered with the [render extension](extension.md). It sits under the copy
  and the device. Do not use a full-tile `decorations` image for this: Goldie 0.3.1
  draws image layers after the headline, so it would hide the copy. Image layers stay
  for small pieces placed away from the copy (a `callout`, a badge).

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

Generate one wide image with the aspect ratio `N × 1206 : 2622` for `N` tiles, and give
every scene its slice with the render extension:

```ts
backgroundImage: { src: "../assets/strip.png", strip: N, index: i } // i = zero-based tile position
```

The extension scales the image to cover the whole strip and crops each tile's slice, so
the picture continues when tiles sit side by side. Keep important content away from
the seams.

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

1. Render the tile with its final layout and a flat mid-gray background.
2. Give that render to image generation as an edit reference: keep the phone, its
   screen and its position unchanged; paint the setting around it (room, desk, hands
   holding it from behind, sky). No text, logos or faces (see [imagegen](imagegen.md)).
3. Use the result as the scene's `backgroundImage` and render again with the same
   layout and theme through the render extension. Goldie draws the real device and
   the real capture on top, in the same place, so the generated phone is covered.

Inspect the edges of the device: if the generated image moved or resized the phone,
the old outline shows around it; generate again. Hands sit behind the device.
Perspective (a phone seen from above at an angle) is not possible; use the tilt
layouts for movement.

## `concept` — a generated image and headline, no device

`layout: "concept"` with a `backgroundImage`, rendered with the render extension. It
needs no capture. Place it after the first three tiles, at most twice and in no more
than a third of the set.

## iPad

Render iPad 13-inch tiles (2064×2752, bare screen) with the render extension and
`--device ipad-13`, from a separate `goldie.ipad.config.ts` that starts from
[assets/ipad.config.ts](../assets/ipad.config.ts). Use the same pattern as iPhone with
iPad placement, and never stretch an iPhone image. See [extension](extension.md).
