---
name: appstore-creative
description: >-
  App Store用のスクリーンショットとプレビュー動画を、まずいくつかのパターンを提案して
  ユーザーに選んでもらい、選んだものだけを作り込む（D-077）。Goldieを土台に、2画面、
  連続背景、使用シーン、生成した背景などを組み合わせる。ストア用スクショの作成・装飾・
  見出しや背景の変更に使う。通常のUI検証スクショには使わない。
---

# App Store creative

Make App Store images that sell the app, not just frame one screenshot under a
headline. Propose several whole-set patterns first, let the user choose, then build
only the chosen one (D-077). Official **Goldie 0.3.1** is the renderer; the template
adds what Goldie lacks. Read [provenance](references/upstream.md) before installing
or updating. This is a local asset workflow, not App Store Connect submission.

## Choose only the requested work

- **Setup only / screenshots on hold:** install, inspect config, run `version` / `help`
  and load the example. Do not launch, reinstall, capture, render, or generate images.
- **Small edit to an adopted set** (headline, background, frame, font, order only):
  import the existing captures and render; no recapture and no new proposal.
- **New set, or "make it look better":** run the flow below, starting with a proposal.
- **New capture:** capture with the repository tool on the dedicated Simulators,
  then import (see [capture and flows](references/flows.md)). Use real app UI and
  synthetic demo content.
- **Preview video:** not available yet; the recording and quality-gate tools arrive
  with the follow-up Issues of D-077. Report it as unavailable instead of recording
  on another device. Screenshot requests do not imply videos.

Respect a user's named platform and previously selected scope. Infer App Store
for a native iOS-only project. Ask about platforms only if genuinely unresolved.

## The flow (D-077)

1. **Prepare.** Confirm real captures exist for each locale; capture missing ones
   with the repository tool. Read `App Store/metadata/`, confirmed specs and the app.
2. **Brief.** Write a short brief: the app's core benefit, mood, colors to use or
   avoid, the real screens worth showing, the tile count (up to 10), and locales.
3. **Stage 1 — compare patterns.** Design three or four whole-set patterns that
   differ in story and composition, not only color. Draw every tile for real with
   Goldie and the render extension at full size, Japanese iPhone only. Each pattern
   may use one generated key image; use real captures and solid or gradient
   backgrounds elsewhere. Build the sheet:

   ```sh
   tools/appstore-creative-sheet.sh build --spec pattern-definition.json \
     --root .artifacts/store-creative --revision <revision>
   ```

   The sheet checks every pattern against the rules below and marks violations.
4. **Show the sheet and ask for a choice.** The local `sheet.html` is the canonical
   sheet. Claude also publishes that exact file as a private Artifact and gives the
   link, so the user can see it on any device; Codex opens the local file in its
   browser. Ask for one pattern ID, or an explicit tile-by-tile combination.
5. **Record the choice.** `tools/appstore-creative-sheet.sh select --sheet
   .artifacts/store-creative/<revision> --pattern <ID>` or `--tiles 1=A:1,2=C:2,...`.
   A vague answer ("like A, but brighter") is not a choice: build a new revision
   that applies it and ask again. Never edit a revision the user has seen.
6. **Stage 2 — the full sample.** Generate the remaining images, render Japanese and
   English for iPhone and iPad, build a `preview` sheet,
   and repeat the choice for changes in a new revision.
7. **Finish.** Export at the exact store sizes, inspect every image, and hand the
   adopted images to `prepare-appstore-assets`. Commit only `goldie/<locale>/`
   configs, adopted generated images in `goldie/assets/`, and
   `goldie/assets/provenance.json`; keep sheets and rejected images out of Git.

Details: [proposal sheet](references/proposal.md), [tile kinds](references/patterns.md),
[image generation](references/imagegen.md).

## Tile kinds

| Kind | What it shows | How |
| --- | --- | --- |
| `device` | Real screen with styling | Goldie layouts and templates |
| `pair` | Two screens, or one screen in two states | `duo` / `duo-tilt` |
| `panorama` | One picture across two tiles | `panorama` / `panorama-duo` |
| `continuous` | One background running through every tile | `backgroundImage` strip (extension) |
| `callout` | A magnified part of a real screen | crop beside the device |
| `scene` | The real device inside a generated setting | generated `backgroundImage` (extension) |
| `concept` | A generated image and headline, no device | `concept` layout (extension) |

Every App Store tile is rendered with `tools/appstore-creative-render.sh` (see
[extension](references/extension.md)). The App Store iPhone size, iPhone 6.3-inch
(1206×2622, `--device iphone-6.3`, D-079), and iPad 13-inch are extension devices, and
Goldie 0.3.1 draws image layers over the headline, so every full-tile generated image
(a generated background, `continuous`, `scene`, `concept`) needs the extension too.

## Rules (D-077)

- The first three tiles show the app in use: never place `concept` there.
- At most two `concept` tiles, and no more than a third of the set.
- Generated images never contain app screens or UI, text, logos, faithful Apple
  hardware, or identifiable faces. Real devices and screens are always drawn by
  Goldie or the extension from real captures.
- Show only features the app has; no ratings, awards, rankings or invented claims.
- Never edit a raw capture. Only `callout` crops one, and it records the source and
  region. Generated images are material and may be scaled or cropped.
- Generated images carry no text and are shared by Japanese and English. Both
  locales use the same tile kinds in the same order; iPhone and iPad use the same
  pattern with device-specific placement.

## Phase 6 boundary and Simulator ownership

This skill is the standard Phase 6 presentation route for App Store images after the
exact release candidate, Phase 5 quality proof, and any required
`evidence-applicability.json` decision are fixed. It is not Phase 3/4 product UI
verification and does not complete a Phase exit, release audit, package seal,
upload, or submit operation. A sealed Issue without `Release-phase binding:` is
`legacy-unbound`; do not add or infer a phase record merely to use this skill.

Every new native capture runs `tools/capture-appstore-screenshots.sh` under
`tools/with-ios-simulator-lock.sh`. It leases only the repository's dedicated
iPhone and iPad Simulators through `tools/lib/ios-simulator-resource.rb` (D-063),
which erases the device before each lease and shuts it down on release without
creating or deleting a device. Since D-070 and D-079 those devices (iPhone 17 Pro and
iPad Pro 13-inch (M5)) are the App Store display sizes, so raw captures are already at the required pixel size; never crop, scale,
or composite them outside the `callout` rule. Import the raw images with the recipe
in [references/config.md](references/config.md#import-existing-captures).

Do not run Goldie's own `capture`. Goldie 0.3.1 has no UDID selector, picks the
first Simulator whose name is exactly a model name in its own device table (never a
dedicated `<display name> …` device), and reinstalls the app there. Preserve images
and diagnostics outside the device and verify the released lease receipts before
rendering. Never boot, erase, or install into a user or other-owner device.

## Runtime

Requires macOS/Xcode for iOS capture, Node >=20.12, ffmpeg/ffprobe. npm packages
include the CLI, renderer, Studio and Argent CLI; an Argent MCP connection is
optional. Do not add global MCP settings just to run Goldie.

Read `references/config.md` for installation, a non-capture config check and commands.
Use the installed CLI with `node "$GOLDIE_RUNTIME/node_modules/goldie/dist/cli.js"`.
Re-use its package-lock; record the resolved Goldie and Argent versions. A version
upgrade is explicit maintenance, not an unannounced `@latest` download each run.
Use the repository's finite-timeout/process-ownership wrappers when available.

## App-specific source

Read existing Goldie config/design/flows first. In iOS-Template, derive app identity,
copy and intended screen order from `App Store/metadata/`, confirmed specs and the
actual app. Do not infer release readiness from a filename or the newest DerivedData.
For capture, build the exact requested Head into a Release simulator build.

Start from [assets/goldie.config.ts](assets/goldie.config.ts). Supply the environment
inputs described in `references/config.md`; replace scene IDs/flows and copy with
observable app features before rendering. Keep configuration in each app:

```text
goldie/ja/goldie.config.ts       # locales: ["ja"]
goldie/en-US/goldie.config.ts    # locales: ["en-US"]
goldie/ja/goldie.design.json    # Studio choices, if present
goldie/assets/                   # adopted generated images and provenance.json
```

**One locale per config directory.** In 0.3.1 capture reads `cfg.locales[0]` and
stores only one raw manifest per device, without a locale segment. Merely specifying
`["ja", "en-US"]` translates headlines over the same app UI. Separate configs/raw
outputs prevent that error. Use `ja` consistently with the template's source folder.

Add `/goldie/**/out/` to the app's `.gitignore` before generating. Commit config,
design choices and adopted assets; never credentials, user data or a developer's
absolute build path. Each output directory is disposable and **owned by Goldie**:
`frame` removes old PNGs there. Keep originals and adopted final assets elsewhere.

## Copy and typography

Aim for short benefit-led Japanese/English headlines. Use a Japanese-capable
installed font (for example Hiragino Sans), and inspect the actual export for tofu,
wrong glyph forms, wrapping and cropping. Bundled Noto Sans SC is not a Japanese
typography guarantee. Studio listing scaffolding is a local preview only.

## Completion

Goldie Studio (`studio --no-open --port <available-port>`) remains available for
fine-tuning a chosen pattern; capture its PID and confirm the URL before opening it.
Goldie's own CLI (`frame`, `manifest`, `verify`) and Studio know only Goldie's own
devices, reject the `concept` layout and ignore `backgroundImage`. Use Studio only to
sketch a layout on Goldie's own iPhone device, then render every App Store tile with
`tools/appstore-creative-render.sh`.

Inspect every selected exported image, including raw-to-framed content, readable
copy, locale parity, safe areas, order and actual pixel dimensions. `verify` checks
Goldie's bundled rule table, not current Apple policy or the repository release
contract. Check the current official requirements and App Review Guidelines before
a real submission. Retain device-frame and font attribution with distributed assets.

Working output stays under `goldie/<locale>/out/` and sheets under
`.artifacts/store-creative/`; only reviewed, adopted images go into
`App Store/screenshots/` through the existing preparation workflow. Goldie manifests
and sheets are not canonical `verify.json`, screenshot audit, release approval or
package seals. Do not overwrite sealed packages or weaken the capture/prepare/submit
gates. This skill does not upload or submit.

Report files, locales/devices, commands that actually passed, and remaining work.
Distinguish setup verified, rendering verified, native capture verified, and release
ready. On failure, inspect and repair the cause; stop after two failures for the
same cause rather than rerunning a complete pipeline indefinitely.
