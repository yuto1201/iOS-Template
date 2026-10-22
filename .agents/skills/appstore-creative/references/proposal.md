# Proposal sheets and the user's choice

`tools/appstore-creative-sheet.sh` turns rendered tiles into one HTML page and records
the user's choice. Sheets live under `.artifacts/store-creative/<revision>/`, which Git
ignores. A revision is never rebuilt or edited; every change gets a new revision.

## Identity (`brand.json`)

Every app keeps one `goldie/brand.json` (D-085). Write it before any pattern, from
the confirmed specs, `App Store/metadata/` and the real app, and check it:

```sh
tools/appstore-creative-sheet.sh check --brand goldie/brand.json \
  --captures goldie/ja/out/raw/iphone-6.3/manifest.json [--style style-A.json]
```

```json
{
  "schemaVersion": 1,
  "app": "花島",
  "strengths": [
    {"id": "sway", "claim": "天気で花が揺れる", "feature": "天気に合わせた花の動き", "screens": ["home-rain"]}
  ],
  "audience": [{"who": "通勤する人", "scene": "朝、家を出る前"}],
  "world": "雨上がりの窓辺に咲く小さな庭",
  "story": ["天気は気になる", "花が教えてくれる", "毎朝のたのしみになる"],
  "colors": {"accent": "#3A7BD5", "icon": ["#F2C94C"],
             "palette": [{"name": "paper", "hex": "#F6F2EA", "use": "背景"}]},
  "fonts": [{"role": "headline", "family": "Zen Maru Gothic", "source": "Google Fonts",
             "license": "SIL Open Font License 1.1", "paid": false}],
  "voice": ["やさしい", "具体的", "静か"],
  "motifs": ["雨粒", "花びら"],
  "avoid": ["意味のない光の玉"]
}
```

- `strengths` (one to five): what the app does better, each tied to the capture states
  (`screens`) that show it. A strength no real screen shows is refused: it would be an
  invented claim. `--captures` (and `captures` in a proposal) names the Goldie raw
  manifest of the real captures (see [config](config.md#import-existing-captures)); every
  screen must be one of its `sceneId`s and its `file` a real PNG or JPEG, so an invented
  screen name is refused even next to a real one.
- `colors.accent` is the app's `AccentColor`; `colors.icon` are colors taken from the
  adopted icon.
- Every font names its `source` and `license`. A font with `"paid": true` is refused
  until the user has approved it and `approval` records that; ask before using one.
- `voice` holds about three words; `avoid` lists what this app's images must not look
  like.

## Style spec (one per pattern)

A style spec fixes one pattern's look so its tiles read as one product, in the format
adapted from ParthJadhav/app-store-screenshots (see [upstream](upstream.md)):

```json
{
  "schemaVersion": 1, "id": "A", "name": "雨の窓辺",
  "signature": "窓ガラスの雨粒が、面をまたいで流れる",
  "tokens": [{"name": "bg", "hex": "#F6F2EA", "use": "背景"}, {"name": "ink", "hex": "#1E1D1B", "use": "見出し"}],
  "fonts": {"headline": "Zen Maru Gothic", "body": "Noto Sans JP"},
  "typesetting": "左寄せ、2行まで、行間は詰める",
  "decorationLimit": 2,
  "crossScreen": "雨粒の層だけが隣の面へ15%まで入る。見出しと顔はまたがせない",
  "voice": ["やさしい"],
  "failures": ["見出しが3行になる", "雨粒が見出しに重なる"],
  "deviations": [{"item": "#0B1F3A", "reason": "夜の場面だけに使う"}]
}
```

- `signature` is the one element that makes the pattern recognizable at thumbnail
  size. Two patterns of one proposal never share it.
- Every token color and font comes from `brand.json`; anything else needs a
  `deviations` entry naming it with the reason, or the spec is refused.
- `decorationLimit` is the number of decorations one tile may carry; `failures` are
  the conditions that make a render wrong, checked by eye with the
  [quality bar](patterns.md#quality-bar) before the user sees it.

## Research record

Before each proposal, look at three to five top apps of the same category (before.click,
the App Store) and write what techniques they use:

```json
{
  "schemaVersion": 1, "category": "天気", "checkedOn": "2026-10-21",
  "references": [
    {"id": "lazy", "app": "Lazy Weather", "site": "before.click",
     "url": "https://before.click/explore?app=lazyweather",
     "techniques": ["story-across"], "notes": "文が次の面へ続く"}
  ]
}
```

Technique IDs are short names you choose, for example `story-across` (one sentence
continues across tiles), `off-screen-world` (the world around the app), `popout` (a
magnified piece of UI leaving the device), `mascot`, `hands`, `cross-tile-art`,
`app-typeface`. Take techniques only: never copy a design, illustration, headline or
logo. The URLs stay in the record; the sheet shows only the apps, sites and techniques.
Keep the record with the revision under `.artifacts/store-creative/`, outside Git.

## Material sheet

Generated material is shown to the user before any pattern uses it (D-085). Write a
material definition and build it like any sheet:

```json
{
  "schemaVersion": 1, "kind": "material", "app": "花島", "title": "素材の確認",
  "brief": "雨上がりの窓辺の庭。",
  "materials": [
    {"id": "cloud", "pattern": "A", "role": "object", "image": "generated/cloud.png",
     "prompt": "雨上がりの小さな雲、水彩、文字なし", "cutout": {"key": "#00FF00"}},
    {"id": "garden", "pattern": "A", "role": "background", "image": "generated/garden.png",
     "prompt": "窓辺の小さな庭、朝の光", "note": "panoramaの左半分に使う"}
  ]
}
```

- `id` and `role` are short lowercase names; `pattern` is the pattern the material is
  for; `prompt` is the generation prompt. `cutout.key` is the key color a cut-out was
  generated on: the build runs the cut-out check on it and refuses a fringe or an opaque
  background before the user sees it.
- The page shows the materials per pattern on a checkerboard, with role, prompt and
  note, and asks for a decision on each. It has the same Content Security Policy,
  embedded images, SHA-256 record and no-replace rule as the other sheets.
- Record the decision with `review --adopt <ids> --reject <ids>`, naming every material
  exactly once. `material-review.json` is written once; `select` does not apply to a
  material sheet.

## Pattern definition

```json
{
  "schemaVersion": 1,
  "kind": "proposal",
  "app": "花島",
  "title": "ストア画像の提案",
  "brief": "雨と風に揺れる花の動きを主役にする。",
  "brand": "../../goldie/brand.json",
  "research": "research.json",
  "captures": "../../goldie/ja/out/raw/iphone-6.3/manifest.json",
  "materialReviews": ["../flower-m1"],
  "renders": ["../../goldie/ja/out/creative-render-iphone-6.3-ja.json"],
  "headlineLimits": {"ja": 16, "en-US": 36},
  "patterns": [
    {
      "id": "A",
      "title": "動きで見せる",
      "hypothesis": "検索結果の3枚で、天気に合わせて花が揺れることを伝える。",
      "tradeoffs": "生成した背景の質に左右される。",
      "recommended": true,
      "recommendation": "最初の3枚だけで、何ができるかと世界観が伝わる。",
      "style": "style-A.json",
      "techniques": ["story-across"],
      "tiles": [
        {"slot": 1, "kind": "scene", "device": "iphone", "locale": "ja",
         "image": "goldie/ja/out/screenshots/iphone-6.3/ja/01-rain.png", "caption": "雨の日",
         "highlight": "sway", "layout": "hero", "background": "illustration", "decorations": 1,
         "headlines": {"ja": ["雨の日も、花が教えてくれる", "今日の空は、花に聞く"],
                       "en-US": ["Let the flowers read the sky", "Rain or shine, at a glance"]}}
      ]
    }
  ]
}
```

- `kind` is `proposal` (stage 1: three to six patterns with the same tile count from the
  brief, Japanese iPhone tiles only; three or four by default) or
  `preview` (stage 2: the chosen pattern, Japanese and English, iPhone and iPad).
- A `proposal` needs `brand`, `research`, `captures` and, per pattern, `recommended`, `style` and
  `techniques`; per tile `highlight` (the one brand strength the tile sells), `layout`,
  `background` and `headlines` (two to six candidates per locale). `decorations` is
  optional. `headlineLimits` is optional; the default guide is 16 Japanese characters
  (spaces not counted) and 36 English characters.
- `renders` names the render records of the tiles (`out/creative-render-<device>-<locale>.json`
  from `tools/appstore-creative-render.sh`) and `materialReviews` the reviewed material
  sheets. Every tile must appear in a render record by its SHA-256; its generated inputs
  (the background slice and each layer that touches it) must all be adopted on a listed
  review, byte for byte. The sheet shows how many adopted materials each pattern uses, and
  `sheet.json` keeps their SHA-256.
- Exactly one pattern is `recommended`, with the `recommendation`: the one you think is
  best. The others carry `"recommended": false` and no reason.
- Headlines are provisional until the App Store copy guide (ASO) exists; then align
  them with it.
- `tiles[].kind` is one of `device`, `pair`, `panorama`, `continuous`, `callout`,
  `scene`, `concept`. A panorama fills two slots. Slots run from 1 in order for each
  device and locale.
- `image` is a rendered tile (PNG or JPEG), relative to the definition file.
- Text fields are plain text. URLs, markup and style imports are refused, so the page
  cannot reach the network.

## Build

```sh
tools/appstore-creative-sheet.sh build --spec definition.json \
  --root .artifacts/store-creative --revision flower-r1
```

The page embeds downscaled copies of the tiles (`--max-dimension`, default 960 px),
has a Content Security Policy that blocks every request, and needs no script. The
record `sheet.json` keeps the page's SHA-256, the definition's SHA-256, each tile's
source SHA-256, and the rule check of each pattern: the first three tiles show the
app, at most two `concept` tiles and no more than a third, and (for `preview`)
Japanese and English use the same kinds in the same order. Patterns that break a rule
are marked on the page and cannot be selected.

A `proposal` sheet also shows the identity, the research (apps, sites and techniques,
no URLs), each pattern's style spec and techniques, the recommendation, and per tile
the strength, layout, background and headline candidates. `sheet.json` adds the
SHA-256 of `brand.json`, the research record and each style spec. The build refuses:

- fewer than three or more than six patterns, or not exactly one recommendation;
- a `brand.json`, style spec or research record with a missing item, a font without a
  license record, an unapproved paid font, a strength tied to no screen or to a screen name with no real
  capture in the `captures` manifest, a color or
  font outside `brand.json` without a reason, or fewer than three reference apps;
- a pattern without a style spec, or using a technique the research does not list;
- a tile in no render record, or drawn from a generated image that no material review
  adopted, that the user rejected, or that changed after the review, and a rejected
  material placed directly as a tile;
- two patterns that share the signature element, or that use the same layouts and
  backgrounds in the same order (one pattern shown twice).

It marks, without blocking a choice: one layout on three or more adjacent tiles, one
strength sold on two tiles of a pattern, a headline candidate longer than the guide,
and more decorations than the style spec allows. Fix marks before showing the sheet
unless you have a reason; say it in `tradeoffs`.

## Show it

- Claude publishes the exact `sheet.html` as a private Artifact and gives the link,
  then asks for a choice. Publishing uploads the tiles to claude.ai as a private page;
  D-077 makes this the standard, and the sheet stays local when the user asks. Do not
  edit the file for publishing.
- Codex opens the local `sheet.html` in its browser and asks for a choice.

## Record the choice

```sh
tools/appstore-creative-sheet.sh select --sheet .artifacts/store-creative/flower-r1 --pattern A
tools/appstore-creative-sheet.sh select --sheet .artifacts/store-creative/flower-r1 --tiles 1=A:1,2=C:2,3=A:3
```

`--tiles` names, for every slot of the set, the pattern and its tile that fills it; it is
allowed only on a stage 1 sheet, must cover every slot, and must still meet the rules. `selection.json`
records the revision, the sheet's SHA-256, the choice and `user-explicit`. It refuses
an unknown pattern, a pattern that breaks the rules, a combination with a missing
slot, a sheet whose bytes changed after it was built, and a second selection. The
patterns and tile kinds a choice is checked against come from a record inside the
displayed page, and the rules are checked again at that moment; an edited `sheet.json`
that no longer matches the page is refused.

Only the user's explicit pattern ID or complete combination counts. Praise, a
ranking, or "something like A" is not a choice: apply the request in a new revision
and ask again.
