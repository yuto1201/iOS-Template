# Generated images

Use Codex's built-in image generation (the `image_gen` tool of its `imagegen` skill).
It needs no API key. Generated images are material: the world around the app
(backgrounds, settings, wide strips), objects, mascots and characters, textures and
concept art. They never replace a real screen.

There is no limit on how many you make (D-085): make as many as the patterns need, and
make more when one does not sell the app. The user sees every material before any
pattern uses it, and only what the user adopts is used.

## Who generates

- **Codex** calls its built-in image generation directly, one call per image.
- **Claude** asks Codex to generate and nothing else, from a scratch directory:

  ```sh
  codex exec --skip-git-repo-check -C "$WORK" -s workspace-write \
    "Use your built-in image generation tool (not SVG, not code, not the CLI fallback) to create ONE image: <prompt>. Request a tall portrait size as close as possible to a 1206x2622 aspect ratio. Copy the generated PNG into the current directory as <name>.png, then print the source path and 'sips -g pixelWidth -g pixelHeight <name>.png'. Do nothing else."
  ```

  For an edit (`scene`, or the next image of a series), attach the reference with
  `-i reference.png` and say what must stay unchanged. Read the session id from the first
  log lines if a follow-up is needed, and resume only that id, never `--last`.
- If built-in generation fails or is unavailable, stop and report it. The CLI
  fallback needs an API key; use it only when the user explicitly asks for it.
- **Paid or credit-consuming generators and tools** (a video generator, a paid upscaler,
  a stock library): stop and ask the user before every use.

## What to make

| Material | Ask for | Used as |
| --- | --- | --- |
| World / setting | the place the app is used, with light and season from `brand.json` | `backgroundImage`, `scene`, `back` layer |
| Wide strip | one picture `N × 1206 : 2622` for `N` tiles | `continuous`, cross-tile art |
| Object | one physical thing (a cup, a plant, a ticket) with its own light and shadow | `front`/`back` layer (cut-out) |
| Mascot / character | one figure in one consistent style, in the pose the tile needs | `front` layer (cut-out) |
| Texture | paper, grain, fabric that the style spec names | background or a subtle layer |
| Concept | the problem or the feeling, no device | `concept` tile |

## Prompts

Describe the subject, mood, light and colors from `brand.json` and the pattern's style
spec. Always add: no text, no letters or numbers, no logos or watermarks, no app screens
or user interface, no recognizable Apple hardware, no identifiable faces. Hands may
appear. Never ask for an image of the app itself; the device and its screen come from
real captures.

## Keep one style across a pattern

1. Generate the first, most important material of the pattern and show it with the other
   first materials on a material sheet (below).
2. Make every further material of that pattern as an **edit with the adopted first
   material as the reference** (`-i first.png`): "same illustration style, line weight,
   palette and light; now draw <next subject>". Do not start each image from a blank
   prompt.
3. Keep the same lighting direction, the palette of the style spec and the same level of
   detail on every tile; a material that drifts from the series is generated again.

## Cut-outs (objects and mascots)

Generation always returns an opaque image, so a cut-out is made in two steps:

1. Generate the subject alone, centered with a margin, on one flat key color that does
   not appear in it (for example pure green `#00FF00`, or magenta `#FF00FF` for green
   subjects). Ask for "a flat, even background of exactly <key>, no shadow on the
   background, no gradient".
2. Separate it into a PNG with alpha (for example
   `ffmpeg -i in.png -vf "colorkey=0x00FF00:0.30:0.08,despill=type=green,format=rgba" out.png`),
   and check it:

   ```sh
   tools/appstore-creative-sheet.sh cutout --image out.png --key '#00FF00'
   ```

   It refuses an image without alpha, one that is not clear along its edges or over at
   least 10% of its area, and one that keeps more than 0.5% of visible pixels close to the
   key color (a fringe). Separate it again, or generate again with a different key.
   Give the key as `cutout.key` on the material sheet so the sheet checks it too.

If cut-outs keep failing for one subject, draw it into a full-tile setting instead
(`scene` or a background) and record why in the material's `note`.

## Reject generic AI images before showing them

Do not show the user anything that makes the app look cheap. Generate again when an
image has:

- meaningless gradients, light orbs, sparkles or bokeh with no subject;
- flat single-tone shapes, or objects with no shadow, texture or volume (it must clear
  three of the five illustration items of the [quality bar](patterns.md#quality-bar));
- the same composition or picture as another tile of the pattern;
- stock-photo poses and smiles, plastic skin, extra fingers or broken anatomy, warped
  objects;
- anything in `avoid` of `brand.json`, or a look the style spec lists as a failure.

Ask: would this make someone want to install the app, and does it show this app's world
rather than any app's? If not, it is not ready to show.

## Size

A tall portrait request returned 851×1849 on 2026-10-12, within 0.1% of the aspect
ratio of the 1206×2622 iPhone tile (D-079). Scale generated material to the exact tile
size before use, for example `sips -z 2622 1206 in.png --out out.png`, and inspect it for softness.
For iPad (2064×2752) or a `continuous` strip, ask for that aspect ratio and keep the
subject inside the area every device crop keeps. Scaling and cropping are allowed for
generated material only, never for real captures.

## Show the materials and record the user's decision

Before any pattern uses a material, show the trial materials on a material sheet and
record the user's decision on each one (D-085):

```sh
tools/appstore-creative-sheet.sh build --spec materials.json --root .artifacts/store-creative --revision <revision>
tools/appstore-creative-sheet.sh review --sheet .artifacts/store-creative/<revision> --adopt cloud,sky --reject dusk
```

`materials.json` lists, per material, `id`, the `pattern` it is for, its `role`, the
`image`, the `prompt` and, for a cut-out, `cutout: { "key": "#00FF00" }` (format in
[proposal](proposal.md#material-sheet)). Claude publishes the sheet as a private
Artifact as for any sheet; Codex opens it locally. Name every material in `--adopt` or
`--reject`: a review that leaves one out is refused, and "the blue ones look nice" is not
a decision — show a new revision and ask again. `material-review.json` keeps the
revision, the sheet's SHA-256, each material's SHA-256 and decision, and `user-explicit`;
it is never replaced.

A proposal then names the reviews in `materialReviews` and the render records of its
tiles in `renders` (the `creative-render-<device>-<locale>.json` files of
`tools/appstore-creative-render.sh`). For every tile, the build reads from its render
record which generated images it was drawn from (the background slice and every layer on
it) and refuses an image the user rejected, one that changed after the review, one never
reviewed, a rejected material used directly as a tile, and a tile in no render record.

## Keep and record

1. Copy each result from Codex's `generated_images` folder into
   `.artifacts/store-creative/<revision>/generated/`. Never reference an image only
   from Codex's own folder.
2. Write the prompt, the mode (`generate` or `edit`), the generator
   (`codex-builtin-imagegen`), the reference image's SHA-256 for an edit, the output's
   SHA-256 and the time beside it.
3. Look at every image before showing it: no text, logos, UI, faces, watermarks or broken
   anatomy, nothing from the generic-AI list above, and it fits the brief. Generate again
   when it does not; stop and ask after two failures with the same cause.
4. When the user adopts a set, copy only the adopted images into `goldie/assets/` and
   list them in `goldie/assets/provenance.json`:

   ```json
   {"schemaVersion": 1, "images": [
     {"file": "cloud.png", "sha256": "sha256:…", "prompt": "…", "mode": "generate",
      "generator": "codex-builtin-imagegen", "generatedAt": "2026-10-22T00:00:00Z",
      "revision": "<proposal revision>", "referenceSha256": null,
      "materialReview": {"revision": "<material revision>", "reviewSha256": "sha256:…", "decision": "adopted"}}
   ]}
   ```

   Check it with `tools/appstore-creative-sheet.sh provenance --file
   goldie/assets/provenance.json --root .artifacts/store-creative`; it refuses an image
   without a material review, one the review rejected, and a file whose SHA-256 differs.

Use a user's own reference image only after the user confirms they hold the rights
to use it; keep it outside Git and record only its SHA-256.
