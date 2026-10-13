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

## Sound and submission

Previews are silent by default; music is made only when the user asks for it
(`ios-media-assets`) and is named as the preview scene's `audio`. Taking an adopted
preview into the release package and App Store Connect is a separate follow-up of
D-077. Check Apple's current preview requirements before a real submission.
