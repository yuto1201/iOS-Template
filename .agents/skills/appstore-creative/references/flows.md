# Capture and Argent flows

In iOS-Template, Goldie does not capture. Raw screenshots come from
`tools/capture-appstore-screenshots.sh` on the repository's dedicated Simulators
and are imported into Goldie for styling.

## Why Goldie capture is not used

Goldie 0.3.1's `capture` has no explicit iOS UDID override. It selects the first
Simulator whose name is exactly a model name in its own device table, in the newest
matching installed iOS runtime, changes locale/appearance and **reinstalls the app, clearing its data**.
iOS-Template captures only on its dedicated Simulators (D-063), named
`<display name> iPhone 17 Pro` and `<display name> iPad Pro 13-inch (M5)`
(D-070, D-079), so Goldie's selector never resolves to them. Do not run Goldie `capture`
or preview recording, pass an invented `--udid` option, rename a device, or create
a device that matches Goldie's selector.

The repository tool reaches each screenshot state through the launch arguments in
`App Store/screenshots/states.json`, not through Argent flows. The rest of this
page is reference for a future route that can drive a dedicated Simulator.

## Argent reference

Goldie ships an Argent CLI. Read its installed `--help` before new tool calls;
MCP is optional. Discover visible labels and accessibility IDs with the live
Simulator tools, then author `.argent/flows/store-*.yaml`. Do not guess selectors.
Use synthetic demo data and no logged-in personal/production accounts.

Do not disable global Argent flags silently. Inspect `argent flags`; if needed,
record/restore the specific prior value, and avoid changes while another task uses
that server. `doctor` reports video watermark even for a screenshot-only config;
a video-only warning needn't expand a still-image request to video work.

## Flows

A minimal pattern (replace bundle and ID with values observed in the app):

```yaml
steps:
  - launch: com.example.actualapp
  - await: { visible: { id: home-title } }
  - await: { idle: true }
```

- A leading `launch` and `executionPrerequisite` are mutually exclusive.
- Prefer IDs stable across locales. For localized labels, use separate ja/en flows.
- Coordinate taps need an `echo` explaining the target and observed geometry.
- Each screenshot flow must reach its own state deterministically. In 0.3.1 Goldie
  reinstalls once per capture invocation, **not once per scene**; `launch` alone does
  not reset records created by earlier scenes. Use idempotent demo setup or owned
  app reset and import independently captured scenes when that is required.
- End with `await idle`. Goldie takes the final screenshot itself.
- Run a failing flow on its leased dedicated UDID before retrying the whole
  pipeline. The CLI already retries one launch-handshake failure; don't add
  unbounded retries.

## Videos, only when requested

Goldie's `capture` cannot reach the dedicated Simulators, so preview footage is
recorded with `tools/record-appstore-preview.sh` instead (D-077). It runs under
`tools/with-ios-simulator-lock.sh`, leases the dedicated device of one family the same
way as the screenshot capture, and records one storyboard per family and locale:

```sh
tools/with-ios-simulator-lock.sh --timeout 0 -- tools/record-appstore-preview.sh record \
  --requirements "App Store/submission/requirements.json" --states "App Store/screenshots/states.json" \
  --storyboard storyboard.json --app-path <Release .app> --bundle-id <id> \
  --source-sha <Head> --build-digest sha256:<hex> --runtime <runtime> \
  --family iphone-6.3 --locale ja --output-root <new directory> --issue <n> --batch-id <id>
```

`--family` is `iphone-6.3` (the dedicated iPhone 17 Pro, D-079) or `ipad-13` (the
dedicated iPad Pro 13-inch (M5)), as named in the submission requirements. The
storyboard lists segments `{id, state, seconds, allowStill}`; `state` is an entry of
`states.json`, `seconds` is 1–30 and the whole storyboard is at most 30 seconds.

After the lease erases and boots the device, the tool writes the device's own language
and locale, restarts it in place and reads them back, so the status bar shows the
recorded locale (launch arguments reach only the app). Then, for each segment, it
installs the Release build, fixes the status bar (9:41, full battery), launches the app
in that state with the fixed date but with animations on, records with
`simctl io recordVideo --codec=h264`, and stops the recorder with SIGINT. A recorder
that does not stop is terminated and the run fails; every failure, timeout, INT or
TERM still stops the recorder and releases the lease, and a lease that cannot be
released fails the run. The clips, the lease receipts and `record.json` are saved
outside the device. The record holds only the schema version, family, locale, device
type, runtime, source SHA, build digest, and for each segment its id, state, seconds,
`allowStill`, relative path and SHA-256; it holds no UDID, session or local path.

Check every trial clip before recording the full storyboard:

```sh
tools/record-appstore-preview.sh check --clip 01-open.mp4 --family iphone --seconds 5 --output quality.json
```

It passes only at the dedicated device's screen size (iPhone 1206×2622, iPad
2064×2752), at least 30 fps on average, within 0.5 s of the planned length, with no
frame gap over 100 ms (or more than 2% of the clip in gaps), no freeze of 0.5 s or
more, and no black frames of 0.1 s or more. A segment marked `allowStill` may hold
still, which also waives the frame-rate and gap checks; black frames always fail. The
JSON result lists the reasons and the thresholds it applied. Exit status 3 means the
clip failed; a failed trial is the moment to record "no video" instead of shipping a
weak preview. App Store previews are 886×1920 for iPhone and 1200×1600 for iPad, 15–30
seconds, H.264; verify the current Apple requirements before a real submission.
