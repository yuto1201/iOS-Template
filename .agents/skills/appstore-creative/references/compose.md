# Compose renderer (D-093)

`tools/appstore-creative-compose.sh compose` is the default renderer for App Store tiles. Each
tile is declared in JSON, laid out in HTML and CSS, and drawn by headless Chromium at the store
size: iPhone 6.3-inch 1206×2622 (`iphone-6.3`) and iPad 13-inch 2064×2752 (`ipad-13`), RGB
without alpha. Goldie remains for importing captures and for a quick draft; the
[render extension](extension.md) still draws the product page header.

```sh
tools/appstore-creative-compose.sh compose --spec goldie/ja/tiles.iphone.json \
  --brand goldie/brand.json --provenance goldie/assets/provenance.json \
  --out .artifacts/store-creative/<revision>/compose-ja-iphone
```

`--out` must be a new folder. It receives `tile-N.png`, the page of each tile under `html/`,
`thumbnails.png` (every tile at 220 px wide) and the render record
`creative-render-<device>-<locale>.json`. List that record in the proposal's `renders`: it has
the same shape as the render extension's, with every generated input of every tile and its
SHA-256, so the proposal sheet refuses a tile drawn from a material the user did not adopt.

Chromium is found at `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome` or in
`$APPSTORE_CREATIVE_CHROME`. Each run uses a new profile, no extensions and no host resolution,
and every page allows only `file:` and `data:` URLs, so nothing is fetched from the network.

## Declaration

```json
{"schemaVersion": 1, "device": "iphone-6.3", "locale": "ja", "style": "editorial",
 "decorationLimit": 4, "fonts": [{"family": "Noto Sans JP", "file": "../fonts/NotoSansJP-Bold.ttf"}],
 "tiles": [{
   "id": "home",
   "background": {"color": "#FFD60A", "grain": 0.06},
   "headline": {"lines": ["給料日まで", "あといくら？"], "size": 124, "color": "#1C1C1E", "top": 150,
                "lineHeight": 1.2, "letterSpacing": -0.02, "highlight": {"text": "あといくら", "band": "#FFFFFF"}},
   "subhead": {"text": "…", "size": 44, "color": "#3A3A3C", "top": 470},
   "badge": {"text": "家計", "color": "#FFFFFF", "background": "#1C1C1E", "top": 80},
   "device": {"capture": "out/raw/iphone-6.3/home.png", "width": 940, "centerX": 603, "top": 640, "rotate": -3},
   "popouts": [{"region": [80, 1180, 1040, 360], "scale": 1.15, "rotate": 4, "border": "#FFFFFF"}],
   "layers": [{"src": "../assets/coin.png", "x": 1040, "y": 700, "width": 360, "z": "front", "rotate": 12, "shadow": true}]
 }]}
```

Paths are relative to the declaration and must be local files; a URL is refused.

- **background** — exactly one of `color`, `gradient` (`from`, `to`, `angle`) or `image` (an
  adopted material), with optional `grain` (0–0.2) laid over it.
- **headline** — one to three lines, `size` in pixels (top apps use about 110–130 on iPhone, two
  lines nearly as wide as the tile), `top`, and an optional `highlight` that colors or bands one
  phrase.
- **device** — a real capture, never edited. The frame is drawn at the tile's resolution (no
  stretched artwork): bezel 3.4% and corner radius 16.5% of the width with a Dynamic Island on
  iPhone, 3% and 6% on iPad. `top` and `width` let it run off the bottom edge; choose the edge by
  where the screen's content is, so the visible part shows it. `rotate` turns it about its
  center (±15°).
- **popouts** — a `region` of the capture in its own pixels, drawn right over the same place on
  the turned screen, magnified by `scale` (1–2) and turned by its own `rotate`. Turn it the
  other way from the device and give it a white or accent `border`.
- **layers** — adopted materials (`goldie/assets/provenance.json` with an `adopted` material
  review and the same SHA-256) placed by center `x`, `y` and `width`, `front` of or `back`
  behind the device.
- **fonts** — only `brand.json` families. A `file` must be in `fonts/` next to the declaration or
  its parent, or in the system or user font folders; without a file the family is used by name.

## Quality marks

The record measures each tile in Chromium and marks it against the
[quality bar](patterns.md#quality-bar): the device's visible height, the tallest empty band, the
widest headline line, the headline's contrast over a color or gradient background (an image
background is left to the eye), and decorations (layers and popouts) over the style's
`decorationLimit`. `style` sets the allowed limit: `minimal` 0, `editorial` 2–5, `maximal` 8–14.
Fix a marked tile or say why in the proposal's `tradeoffs`.
