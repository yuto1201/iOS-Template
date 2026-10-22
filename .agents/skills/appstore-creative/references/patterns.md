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

## Techniques that make a set distinctive

Top apps (researched on before.click, 2026-10-21) rarely let the screenshot carry the
tile alone. Combine these with the tile kinds above; record the ones you take in the
research record and the pattern's `techniques`.

- **Story across tiles** (`story-across`): the tiles read as one argument — a problem,
  then the answer, then the habit — and a sentence may continue onto the next tile.
- **The world around the app** (`off-screen-world`): illustration, objects, hands or a
  setting that show where and why the app is used, through `scene`, `continuous` and
  generated backgrounds.
- **A piece of UI leaving the device** (`popout`): one card or number magnified next to
  the device (`callout`), so the benefit reads at thumbnail size.
- **A character or object with a role** (`mascot`): a mascot or object that recurs on
  every tile, in one consistent style.
- **Art across the seam** (`cross-tile-art`): an illustration or background that crosses
  into the next tile, within the quality bar below.
- **The app's own typeface and color** (`app-typeface`): headlines in the face and color
  the app uses itself, from `brand.json`.

### Combinations that work

Recipes with the [render extension](extension.md#layers-popouts-frames-and-stories-d-085):

- **Device and mascot**: `device` tile with a `front` mascot layer (`shadow: true`) beside
  the device bottom, half of it outside the device outline.
- **World behind the screen**: `frame: "bare"` with `back` layers of the setting (clouds,
  shelves, a desk edge) on a `#RRGGBB` or generated background, so the screen sits inside
  the world rather than on a color.
- **Benefit at thumbnail size**: `device` or `frame: "crop"` with a `popout` of the one card
  or number the headline promises, at about half the tile width.
- **Two tiles, one picture**: a `background` or `abstract` layer that crosses 20–40% into the
  next tile, under two `device` tiles of different layouts.
- **Problem, then answer**: a `theme.stories` sentence across a `concept` tile (the
  problem, drawn as an illustration) and the `device` tile that answers it.

Keep one cross-tile moment per five tiles, and check every tile alone at thumbnail size.

## Quality bar

Adapted from ParthJadhav/app-store-screenshots (MIT, see [upstream](upstream.md)) to the
App Store sizes of D-079. Proportions are of the tile, so they hold for iPhone and
iPad. Check every tile against it before the user sees a sheet; the `failures` of the
pattern's style spec add to it.

- **Composition.** A device fills 68–82% of the tile height; headline and device
  together cover at least 80%, and no empty band is taller than 22%. Anchor the device
  to an edge rather than floating it with empty bands above and below. At most three
  visual layers per tile: background, device or illustration, headline with one accent.
- **Headlines.** At most three lines, two preferred; break lines by hand so they are
  about equal or deliberately short-long. A word wider than 88% of the tile is broken,
  resized or hyphenated, never cut off. Display leading at most 1.05 and slightly
  negative tracking (−0.01 to −0.03 em). The sheet marks candidates longer than the
  headline guide.
- **Contrast.** Headline text clears 4.5:1 against the worst pixel under it, not the
  average; an emphasis color clears 4.5:1 on its own; labels under the size of body text
  clear 7:1. Over a busy picture add a scrim or move the text.
- **Illustrations and objects (not clip art).** Each one clears at least three of: two
  or more tones per major shape; a soft contact shadow; a surface texture (grain,
  paper, halftone); a volume cue (shaded side, highlight, or a line that thickens in
  shadow); detail suited to its size. A mascot on a cover tile is at least 13% of the
  tile height; a hero object is at least 38% of the tile width.
- **Across tiles.** In a set of five or more, use one cross-tile moment (two at most in
  eight to ten). 10–30% of an element may cross the seam, more only for backgrounds and
  abstract paths. Never let a headline, the app name, a face, a key number or a claim
  cross. Each exported tile still reads alone at thumbnail size.
- **Variety.** Adjacent tiles change layout or device placement; the sheet marks a
  layout used on three adjacent tiles. Each tile sells one strength; the sheet marks a
  strength repeated within a pattern.
- **Generic AI look.** Reject before showing: meaningless gradients and light orbs,
  flat single-tone shapes, objects without shadow or texture, the same picture on every
  tile, stock-photo smiles, and anything in the `avoid` list of `brand.json`.

## iPad

Render iPad 13-inch tiles (2064×2752, bare screen) with the render extension and
`--device ipad-13`, from a separate `goldie.ipad.config.ts` that starts from
[assets/ipad.config.ts](../assets/ipad.config.ts). Use the same pattern as iPhone with
iPad placement, and never stretch an iPhone image. See [extension](extension.md).
