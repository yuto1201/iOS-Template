# Render extension

`tools/appstore-creative-render.sh` renders a Goldie config with the additions that
Goldie 0.3.1 lacks (D-077, D-079, D-085). It loads the pinned runtime's published modules and
changes them only inside its own process; the installed runtime is never written to.

```sh
tools/appstore-creative-render.sh render --config goldie/ja/goldie.config.ts --device iphone-6.3 --locale ja
tools/appstore-creative-render.sh render --config goldie/ja/goldie.ipad.config.ts --device ipad-13 --locale ja
tools/appstore-creative-render.sh describe
```

It uses `$GOLDIE_RUNTIME`, or `${XDG_CACHE_HOME:-$HOME/.cache}/codex-goldie/0.3.1`, and
stops before writing anything when that runtime is not Goldie 0.3.1. Output goes to
Goldie's usual `out/screenshots/<device>/<locale>/` as RGB PNGs without alpha, and a
record `out/creative-render-<device>-<locale>.json` keeps the Goldie version, the
added definitions, the background images used and each file's SHA-256.

A config that uses an addition must always be rendered with this tool: Goldie's own
`frame` rejects the `concept` layout and ignores `backgroundImage`. For a config that
uses none of them on Goldie's own `iphone-6.9`, the tool's output is pixel-identical to
Goldie's `frame`.

## iPhone 6.3-inch

`--device iphone-6.3` renders 1206×2622 tiles, the App Store iPhone size since D-079
(Dynamic Island, medium display). It uses Goldie's own iOS frame, which is already the
iPhone 17 Pro artwork and whose screen has the same aspect ratio to within 0.1%, so the
dedicated iPhone 17 Pro capture fills the screen without cropping. The device entry also
carries the iPhone preview video size, 886×1920. Import captures into
`out/raw/iphone-6.3/manifest.json` as in [config](config.md#import-existing-captures).

## `concept` layout

`layout: "concept"` draws the headline at the top over the background and image layers
and no device, so the scene needs no capture. Give it a `backgroundImage`.

## `backgroundImage`

A screenshot scene, or `theme` for every scene, may name a background image that sits
under the headline and the device:

```ts
backgroundImage: "../assets/rain-sky.png"                          // one tile
backgroundImage: { src: "../assets/strip.png", strip: 5, index: 2 } // tile 3 of a 5-tile strip
```

Paths resolve against the config file. The tool renders those scenes on a transparent
background, scales the image to cover the scene (or the whole strip), crops each tile's
slice and places it underneath. A `panorama` scene covers two consecutive slices. The
tool refuses a slice past the end of its strip, an image that does not exist, and two
scene ids where one is the other plus `-<number>`.

Choose `theme.headlineColor` and `subheadColor` for contrast against the image;
Goldie's automatic light/dark copy color reads only hex colors in `theme.background`.

## Layers, popouts, frames and stories (D-085)

These draw the world around the app and a story across tiles. The tool composes them with
the pinned runtime's own `@napi-rs/canvas` after Goldie renders, and writes RGB PNGs as
before. Positions and widths are fractions of the tile, so one config works for iPhone and
iPad; a layer's height follows its image.

### `layers` — illustrations and objects in front of or behind the device

```ts
layers: [
  { src: "../assets/cloud.png", position: "back", x: 0.62, y: 0.30, width: 0.5, role: "background" },
  { src: "../assets/mascot.png", position: "front", x: -0.05, y: 0.72, width: 0.32, rotate: -8, shadow: true, role: "mascot" }
]
```

- `src` is a PNG with transparency (a cut-out illustration or object, see
  [image generation](imagegen.md)). `position` is `front` (over the device and copy) or
  `back` (between the background and the device). `rotate` is in degrees; `shadow` adds a
  soft contact shadow.
- A `back` layer needs a background the tool paints itself: a `backgroundImage`, or a
  `#RRGGBB` background on the scene or theme. Gradients are refused for those scenes.
- A layer that runs past its tile continues on the next one: the tool places it on the
  strip of all tiles. At most 30% of a layer may cross into a neighbor, 40% for `role`
  `background` or `abstract`. A layer whose `role` is `headline`, `app-name`, `face`,
  `key-number` or `claim` never crosses a seam. Set other limits with
  `theme.crossTile: { max, abstractMax, protectedRoles }`; `protectedRoles` adds roles to
  those five and can never remove one. The crossing is the share of the
  layer outside the one tile that holds most of it, measured on the bounds it is drawn with
  after `rotate`, at every exported seam — the seam inside a two-tile `panorama` scene
  counts too. A `back` layer that crosses needs a paintable background on both tiles; the
  tool renders the neighbor transparent and paints its own `#RRGGBB` background under it.

### `popouts` — a magnified piece of the real screen

```ts
popouts: [{ region: { x: 100, y: 1500, width: 400, height: 300 }, x: 0.04, y: 0.70, width: 0.5, radius: 24, shadow: true }]
```

`region` is in pixels of the scene's raw capture (from `out/raw/<device>/manifest.json`);
the tool magnifies it into a rounded card with a shadow at `x`, `y`, `width`. It reads the
capture and never changes it, and refuses a region outside the capture. The record keeps the
capture's SHA-256 and the region, which is the D-077 `callout` provenance.

### `frame` — the device, a bare screen, or part of the screen

`frame: "device"` (default) keeps Goldie's device. `frame: "bare"` draws the whole capture as
a rounded screen with a shadow and no bezel; `frame: "crop"` draws only `crop: { x, y,
width, height }` of it. Both use the copy of the `concept` layout and place the screen with
`screen: { x, y, width }` (default: centered, `width: 0.78`, `y: 0.27`, running off the
bottom edge).

### `theme.stories` — one sentence across tiles

```ts
stories: [{ scenes: ["problem", "answer"], text: { ja: "天気アプリは複雑すぎる。だから花に聞く。" }, breaks: { ja: [12] } }]
```

The scenes must be consecutive. `breaks` are character positions where the sentence moves
to the next tile, one fewer than the scenes, per locale; each part becomes that scene's
headline, with `…` at the joins unless `ellipsis: false`. Read every tile alone afterwards:
each part must still make sense on its own at thumbnail size.

### Visual layers

The record marks a tile with more visual layers than `theme.layerLimit` (default 4:
background, device or illustration, headline, one accent). Layers, popouts and a layer
coming in from a neighbor each count. Fix the tile or say why in the proposal's `tradeoffs`.

The render record adds `layers` (scene, image SHA-256, position, role, tiles, crossing),
`popouts` and `screens` (capture, its SHA-256 and region), `stories` (the parts) and
`marks`.

## iPad 13-inch

`--device ipad-13` renders 2064×2752 tiles with a bare screen (rounded corners and a
shadow, no bezel). The screen keeps the iPad capture's aspect ratio, so no capture pixel
is cropped. Goldie's layouts place the device and size the copy for a portrait phone
tile; on the wider iPad tile they keep the copy at phone width and center it, and the
tilted layouts push a large device off the edge. Inspect every iPad tile, and prefer
`classic`, `hero` and `concept`. A `goldie.design.json` beside both configs applies to
both, so keep Studio choices that should differ out of it.

Import iPad captures into `out/raw/ipad-13/manifest.json` with the same shape as the
iPhone import in [config](config.md#import-existing-captures). Start from
[assets/ipad.config.ts](../assets/ipad.config.ts). The device entry also carries the
iPad preview video size, 1200×1600.

Goldie 0.3.1 takes custom device geometry only from its Android frame setting, so the
iPad entry uses that path internally with the bezel switched off. This is the reason
the tool pins the Goldie version; re-check it before any upgrade.
