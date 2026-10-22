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
`decorations` (Goldie's image decorations of each scene and the theme: path, SHA-256 and
tiles), `popouts` and `screens` (capture, its SHA-256 and region), `stories` (the parts) and
`marks`. With `backgrounds` it lists every image input of every tile apart from the real
captures, and says so with `inputInventory: "complete-v1"`; the proposal sheet reads it to
check that every generated input was adopted by the user and refuses an older record
without that mark.

## Product page header (D-085)

Since 2026-10-05 a product page can open with a **product page header**: a 21:9 image or
video above the screenshots, shown on iOS 27 and iPadOS 27 (see
[Showcase your apps with new assets on the App Store](https://developer.apple.com/news/?id=ljpl7kyn)
and [Creative assets specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/creative-assets-specifications/)).
It may show the app's world, a season or new content beyond the app's screens. Make it only
when the user wants one; "no header" is always a valid answer.

- **Format:** 3840×1646. Image: `.png`, `.jpg` or `.jpeg` without transparency. Video:
  `.mov`, `.m4v` or `.mp4`, 30 or 60 fps, 5 to 30 seconds. The video always loops and is
  muted by default (people can unmute it on the product page), so it must not depend on
  sound and its loop must not jump.
- **Safe area:** text, logos and the focal point stay inside x 1097–2743, y 493–1154
  (1646×661), the `Art Safe Area` layer of Apple's official template
  (`creative_assets-product_page_header_template-static.psd`, checked 2026-10-22, from
  [App Store Asset Best Practices and Resources](https://developer.apple.com/app-store/asset-best-practices/)).
  Devices and orientations crop the rest differently, and the top corners carry the back
  and share buttons. Recheck the template before a real submission, and look at every
  crop in App Store Connect's **Preview tool** before publishing.
- **One clear idea** for someone who has never seen the app, in the voice of `brand.json`.

### Header still — `render-header`

```sh
tools/appstore-creative-render.sh render-header --spec header.json --out goldie/header/header.png
tools/appstore-creative-render.sh describe-header
```

```json
{
  "schemaVersion": 1,
  "background": {"image": "../assets/garden-wide.png"},
  "layers": [
    {"src": "../assets/garden-left.png", "x": 0.0, "y": 0.1, "width": 0.3, "role": "decoration"},
    {"src": "../assets/mascot.png", "x": 0.42, "y": 0.34, "width": 0.16, "role": "focal", "shadow": true}
  ],
  "texts": [{"text": "雨の日も、花が教えてくれる", "x": 0.5, "y": 0.31, "size": 0.05, "align": "center", "color": "#1E1D1B", "font": "Zen Maru Gothic"}]
}
```

Positions and widths are fractions of the header. `background` is `#RRGGBB` or an image
that covers the header. Every text, and every layer whose `role` is `headline`, `logo`,
`focal`, `app-name`, `claim`, `key-number` or `face`, must lie inside the safe area (after
rotation) and outside the top corners, or nothing is written; decoration layers may run to
the edges. A `safeArea` override must name the official template, its Apple URL and the
date it was checked. The output is an opaque RGB PNG with a record beside it
(`header.png.json`: safe area and its source, each input image's SHA-256, the text).
Generated images for a header are material like any other: show them on a material sheet
before use.

### Header video — `encode-header`

```sh
tools/appstore-creative-preview.sh encode-header --background goldie/header/header.png \
  --clip recordings/garden.mp4 --screen 0.30,0.30,0.40 --output goldie/header/header.mp4
tools/appstore-creative-preview.sh verify-header --video goldie/header/header.mp4
```

It places a recording from the dedicated Simulator (`tools/record-appstore-preview.sh`) or
an adopted video on the header still at `--screen x,y,width` (fractions; a `focal` clip,
the default, must fit the safe area) and writes a silent H.264 video at `--fps 30` or
`60`. By default the last half second crossfades into the start (`--loop crossfade`), so
the video is the clip's length minus half a second and the loop does not jump. Without a
clip, `--seconds` makes a still loop. It refuses a background that is not 3840×1646,
another frame rate, a length outside 5 to 30 seconds, an audio track, and a video whose
first and last frames differ by more than `--seam-threshold` (mean of 0–255 on a 10× smaller
frame, default 6). `verify-header` runs the same checks on a finished video. Music is added
only when the user asks for it.

### Choosing a header

Show two or more options on a header sheet and record the user's choice of one, or of no
header (see [proposal](proposal.md#header-sheet)).

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
