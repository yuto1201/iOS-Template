# Render extension

`tools/appstore-creative-render.sh` renders a Goldie config with four additions that
Goldie 0.3.1 lacks (D-077, D-079). It loads the pinned runtime's published modules and
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
