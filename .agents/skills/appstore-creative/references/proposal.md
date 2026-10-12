# Proposal sheets and the user's choice

`tools/appstore-creative-sheet.sh` turns rendered tiles into one HTML page and records
the user's choice. Sheets live under `.artifacts/store-creative/<revision>/`, which Git
ignores. A revision is never rebuilt or edited; every change gets a new revision.

## Pattern definition

```json
{
  "schemaVersion": 1,
  "kind": "proposal",
  "app": "花島",
  "title": "ストア画像の提案",
  "brief": "雨と風に揺れる花の動きを主役にする。",
  "patterns": [
    {
      "id": "A",
      "title": "動きで見せる",
      "hypothesis": "検索結果の3枚で、天気に合わせて花が揺れることを伝える。",
      "tradeoffs": "生成した背景の質に左右される。",
      "tiles": [
        {"slot": 1, "kind": "scene", "device": "iphone", "locale": "ja",
         "image": "goldie/ja/out/screenshots/iphone-6.9/ja/01-rain.png", "caption": "雨の日"}
      ]
    }
  ]
}
```

- `kind` is `proposal` (stage 1: three or four patterns with the same tile count from the
  brief, Japanese iPhone tiles only) or
  `preview` (stage 2: the chosen pattern, Japanese and English, iPhone and iPad).
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
