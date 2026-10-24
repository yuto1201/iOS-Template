# App Store preview video

Make a preview only when the user asks for one, and only when it is good enough: a
weak preview is worse than none. D-077 gives three gates, and "no video" is a valid
outcome at each of them.

## 1. Storyboard

Propose exactly two storyboards for one family and locale. Each frame is a still of one
segment with the `states.json` state it starts from, its seconds, and what moves. A
storyboard runs 15 to 30 seconds in total. Build the sheet and record the choice:

```sh
tools/appstore-creative-sheet.sh build --spec storyboard.json --root .artifacts/store-creative --revision <revision>
tools/appstore-creative-sheet.sh select --sheet .artifacts/store-creative/<revision> --pattern <ID>
```

The definition uses `"kind": "storyboard"` and exactly two patterns, one per storyboard,
both for the same device and locale; frames carry `slot`, `device`, `locale`, `image`,
`state`, `seconds` and an optional `motion` and `caption`. The sheet has the same
safety as an image proposal ([proposal](proposal.md)): no network access, SHA-256
records, and a revision that is never rebuilt. A storyboard outside 15 to 30 seconds is
marked and cannot be chosen, and the choice is one listed storyboard ID, never a mix.
Show the sheet the same way as an image proposal.

If the app needs a demo-only behavior to show its motion (a sped-up clock, for
example), that is an app change in the app's own Issue, not part of this workflow.

## 2. Trial recording

Record the first segment alone on the dedicated Simulator and run the quality gate
([flows](flows.md#videos-only-when-requested)):

```sh
tools/record-appstore-preview.sh check --clip <clip> --family iphone --seconds <n> --output trial-quality.json
```

When it fails (stutter, freeze, black frames, wrong size or length), show the result
and offer: record "no video", or use the user's own screen recordings from a real
device. Do not loosen the gate.

## 3. Full recording and draft

Record every segment, then encode the draft. iPhone recordings (1206×2622 from the
dedicated iPhone 17 Pro) become 886×1920 previews through Goldie with the render
extension's `iphone-6.3` device; iPad recordings (2064×2752) become 1200×1600 through
its `ipad-13` device:

```sh
tools/appstore-creative-preview.sh encode --config goldie/ja/goldie.config.ts --device iphone-6.3 --locale ja \
  --record <recording directory> --output .artifacts/store-creative-previews/<name>-iphone-ja
```

The Goldie config needs a `kind: "preview"` scene whose segment ids match the recorded
segments in order. `encode` passes each clip through the quality gate, refuses a total
outside 15 to 30 seconds (each clip counts the time its last frame is shown), renders with Goldie (H.264, 30 fps, a silent AAC track unless
the scene names `audio`), checks the result's size, codec, frame rate, length and audio
track and passes it through the quality gate again, and writes `preview.mp4`,
`encode.json` and every quality result to a new directory.

For the user's own recordings, list them with `--user-clips clips.json`
(`{"schemaVersion":1,"clips":[{"segmentId":"seg1","path":"IMG_0001.mp4"}]}`). They may
come from any portrait device at least as wide as the preview; they are recorded as
`user-supplied` with their original path and SHA-256. The AI never operates the
user's device.

## 4. Decision

Show the draft and ask the user to adopt it or ship no video. Record the answer in
`preview-decision.json`:

```sh
tools/appstore-creative-preview.sh decide --output .artifacts/store-creative-previews/<name>/preview-decision.json \
  --revision <revision> --decision adopt --reason "<the user's words>" --encode <encode directory> --trial trial-quality.json
tools/appstore-creative-preview.sh decide --output .artifacts/store-creative-previews/<name>/preview-decision.json \
  --revision <revision> --decision no-video --reason "<the user's words>" --trial trial-quality.json
```

`adopt` accepts only an encode whose clips and video all passed the quality gate and
whose video still matches its record, and records the video's SHA-256. `no-video` can
be recorded at any gate, with or without a trial result. Every decision needs a reason,
and a decision is recorded once. Keep encodes and decisions under
`.artifacts/store-creative-previews/`, apart from the sheet revisions, which are never
written to after they are built.

## 5. Poster frame (D-085)

An App Preview plays muted on the product page; people who turned autoplay off, and
everyone before playback starts, see only its poster frame. Unless another is chosen,
Apple uses the frame at 5 seconds
([App preview specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/app-preview-specifications/),
[App Previews](https://developer.apple.com/app-store/app-previews/)). Choose a frame that
shows the app's strength by itself, with no motion blur and no transition:

```sh
tools/appstore-creative-preview.sh poster-frames --video previews/iphone-ja.mp4 \
  --times 2,5,12.5 --out .artifacts/store-creative-previews/poster-iphone-ja
```

It writes one still per time and `poster-frames.json` (the video's SHA-256 and each still's
SHA-256) to a new directory, and refuses a time outside the video. Show them on a poster
sheet and record the user's choice:

```json
{"schemaVersion": 1, "kind": "poster", "app": "花島", "title": "ポスターフレーム",
 "video": "../store-creative-previews/iphone-ja.mp4",
 "candidates": [{"id": "t5", "seconds": 5.0, "image": "../store-creative-previews/poster-iphone-ja/t5.png", "note": "花が開く"}]}
```

`appstore-creative-sheet.sh build` refuses a candidate outside the video's length;
`select --pattern <ID>` records the candidate, its time, the frame's and the video's SHA-256
and `user-explicit` in `selection.json`, once. Setting the poster frame in App Store
Connect is part of the later upload.

## Check every asset against Apple's current specifications (D-085)

`tools/lib/appstore-creative-preview.rb` keeps one specification table for every asset
this skill exports, with Apple's pages and the day they were read
(`tools/appstore-creative-preview.sh describe-specs`):

| Kind | Size | Format | Length / frame rate |
| --- | --- | --- | --- |
| `screenshot-iphone` | 1206×2622, 1179×2556 (and landscape), D-079 | png, jpg, jpeg, no alpha | — |
| `screenshot-ipad` | 2064×2752, 2048×2732 (and landscape), D-079 | png, jpg, jpeg, no alpha | — |
| `preview-iphone` | 886×1920 or 1920×886 | mov, m4v, mp4 (H.264 or ProRes) | 15–30 s, 30 fps, ≤ 500 MB |
| `preview-ipad` | 1200×1600 or 1600×1200 | mov, m4v, mp4 (H.264 or ProRes) | 15–30 s, 30 fps, ≤ 500 MB |
| `header-image` | 3840×1646 | png, jpg, jpeg, no alpha | — |
| `header-video` | 3840×1646 | mov, m4v, mp4 | 5–30 s, 30 or 60 fps |
| `search-image` | 3:2, 1920×1280 to 3840×2560 | png, jpg, jpeg, no alpha | — |
| `search-video` | 3:2, 1920×1280 to 3840×2560 | mov, m4v, mp4 | 5–30 s, 30 or 60 fps |
| `universal-image` | 5244×2950 | png, no alpha | — |

Sources: [Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/),
[App preview specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/app-preview-specifications/),
[Creative assets specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/creative-assets-specifications/).

Before handing anything to `prepare-appstore-assets`, check each file:

```sh
tools/appstore-creative-preview.sh check-assets --kind header-video --file goldie/header/header.mp4
```

It reads the content, not only the name (a PNG or JPEG signature, PNG transparency
through an alpha channel or a `tRNS` chunk, a MOV/MP4 container), and refuses a file
whose size, format, transparency, length, frame rate or codec is outside its kind, and stops when the table was read more than `maxAgeDays` (90) days ago
(`--max-age-days` changes the limit for one run). Then read Apple's pages again, update the
table and its `checkedOn` date in a change of its own, and check again. Apple changes these
rules; a passing check is not a substitute for reading them before a real submission.

## Sound and submission

Previews are silent by default; music is made only when the user asks for it
(`ios-design-audio-asset`) and is named as the preview scene's `audio`. Taking an adopted
preview into the release package and App Store Connect is a separate follow-up of
D-077. Check Apple's current preview requirements before a real submission.
