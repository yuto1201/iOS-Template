---
name: goldie
description: >-
  GoldieでiOSアプリのApp Store用スクリーンショットを装飾・編集し、依頼時に
  Simulator撮影やプレビュー動画を作る。Goldieの導入、ストア用スクショ、
  画像の見出し・背景・端末枠の変更に使う。通常のUI検証スクショには使わない。
---

# Goldie for Codex

Use official **Goldie 0.3.1** as the renderer; this skill adapts its workflow for
Codex and iOS-Template. Read [provenance](references/upstream.md) when installing
or updating. This is a local asset workflow, not App Store Connect submission.

## Choose only the requested work

- **Setup only / screenshots on hold:** install, inspect config, run `version` / `help`
  and load the example. Do not launch, reinstall, capture, render, or start video work.
- **Existing screenshots / styling:** inspect the provided real app images, use the
  import procedure below, then `frame` → `manifest` → `verify`. Do not recapture
  for a headline, background, frame, layout, order, or font-only change.
- **New capture:** read [capture and flows](references/flows.md). Use real app UI,
  synthetic demo content and an explicitly owned disposable Simulator.
- **Preview video:** add preview segments only when requested. Screenshot requests
  do not imply videos; do not use `all` as the default command.

Respect a user's named platform and previously selected scope. Infer App Store
for a native iOS-only project. Ask about platforms only if genuinely unresolved.

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
For capture, build the exact requested Head into an owned Release simulator build.

Start from [assets/goldie.config.ts](assets/goldie.config.ts). Supply the environment
inputs described in `references/config.md`; replace scene IDs/flows and copy with
observable app features before rendering. Keep configuration in each app:

```text
goldie/ja/goldie.config.ts       # locales: ["ja"]
goldie/en-US/goldie.config.ts    # locales: ["en-US"]
goldie/ja/goldie.design.json    # Studio choices, if present
.argent/flows/store-*.yaml       # only flows that actually exist
```

**One locale per config directory.** In 0.3.1 capture reads `cfg.locales[0]` and
stores only one raw manifest per device, without a locale segment. Merely specifying
`["ja", "en-US"]` translates headlines over the same app UI. Separate configs/raw
outputs and locale-specific flows prevent that error. `--locale` alone does not
change the capture locale. Use `ja` consistently with the template's source folder.

Add `/goldie/**/out/` to the app's `.gitignore` before generating. Commit config,
flows and design choices; never credentials, user data or a developer's absolute
build path. Each output directory is disposable and **owned by Goldie**: `frame`
removes old PNGs there. Keep originals and already adopted final assets elsewhere.

## Existing raw images

0.3.1 has no `import` command. Follow the exact manifest recipe in
[references/config.md](references/config.md#import-existing-captures). Use only
real images whose app, locale and provenance are known. Do not resize an iPad
capture into an iPhone bezel or invent simulator/capture evidence.

For copy, aim for short benefit-led Japanese/English headlines. Use the existing
app's visual direction; don't require a new direction comparison for every edit.
Use a Japanese-capable installed font (for example Hiragino Sans), and inspect the
actual export for tofu, wrong glyph forms, wrapping and cropping. Bundled Noto Sans
SC is not a Japanese typography guarantee. Never invent ratings, awards or privacy
claims; Studio listing scaffolding is a local preview only.

## Preview and completion

Start Studio with `studio --no-open --port <available-port>`, capture its PID and
confirm the actual URL before opening it with Codex browser tools. CUA/in-app
browser can inspect Studio; Argent CLI can inspect Simulator UI, so do not depend
on Claude-specific tools such as AskUserQuestion, Bash or TodoWrite.

Inspect every selected exported image, including raw-to-framed content, readable
copy, locale parity, safe areas, order and actual pixel dimensions. `verify` checks
Goldie's bundled rule table, not current Apple policy or the repository release
contract. Check current official requirements before a real submission.

0.3.1 supports `iphone-6.9` (1320×2868) and Android `pixel-10-pro`, **not iPad**.
For iPad keep the existing `tools/capture-appstore-screenshots.sh` path or a separately
verified renderer. Do not claim a complete universal iOS screenshot set from Goldie.
Retain device-frame and font attribution with distributed assets.

In iOS-Template, working output stays under `goldie/<locale>/out/`; only reviewed,
adopted images go into `App Store/screenshots/` through the existing preparation
workflow. Goldie manifests are not canonical `verify.json`, screenshot audit,
release approval or package seals. Do not overwrite sealed packages or weaken the
existing capture/prepare/submit gates. This skill does not upload or submit.

Report files, locales/devices, commands that actually passed, and remaining work.
Distinguish setup verified, rendering verified, native capture verified, and release
ready. On failure, inspect and repair the cause; stop after two failures for the
same cause rather than rerunning a complete pipeline indefinitely.
