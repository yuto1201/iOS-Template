# Capture with Argent

Goldie ships an Argent CLI. Read its installed `--help` before new tool calls;
MCP is optional. Discover visible labels and accessibility IDs with the live
Simulator tools, then author `.argent/flows/store-*.yaml`. Do not guess selectors.
Use synthetic demo data and no logged-in personal/production accounts.

## Device ownership before capture

Goldie 0.3.1's `capture` has no explicit iOS UDID override. It selects the first
Simulator named `iPhone 17 Pro Max` in the newest matching installed iOS runtime,
changes locale/appearance and **reinstalls the app, clearing its data**. It does
not guarantee this device is disposable. Don't pass an invented `--udid` option,
rename an existing user device, or silently install into the selected default.

Prefer the repository's owned-device capture tool and import its raw outputs into
Goldie. When direct Goldie capture is requested, first resolve the exact candidate
from `xcrun simctl list devices available --json` using the installed version's
selection rule. It may run only if that candidate was created for this task and
its UDID is recorded as owned. If a user-owned device would be selected, use the
owned-UDID Argent CLI/simctl capture route and the import recipe instead. Shut down
or delete only a device created by the current task. Keep existing devices intact.

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
- Run a failing flow on its owned UDID before retrying the whole pipeline. The CLI
  already retries one launch-handshake failure; don't add unbounded retries.

## Videos, only when requested

Add a `kind: "preview"` scene with segments `{id, flow, holdSeconds}`. The first
segment launches, later ones may declare `executionPrerequisite` describing the
previous final state. Check continuity and deliberate pacing. `capture` also
records all preview segments present in config; use a screenshot-only config when
no video was requested. Then run `preview`, `manifest`, `verify`.

Goldie 0.3.1 targets 15–30 seconds and 886×1920 H.264 for its iPhone preview. Use
real UI recordings and verify current Apple requirements for actual submission.
A successful image `verify` is not proof of video creation or App Store acceptance.
