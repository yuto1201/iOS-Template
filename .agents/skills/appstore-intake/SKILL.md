---
name: appstore-intake
description: Take App Store screenshots, store copy or other store creative made in the App Store creative workspace into this app — check the delivery, bind it to the app's own raw captures and the user's recorded choice, then hand it to the app's assembly, review, seal and save gates (D-105). Use when the workspace session says a delivery is ready, or the user asks to put adopted App Store images or copy into the app. Not for making, proposing or restyling images or copy (that happens in the workspace with the shared `appstore-creative` skill), and not for App Store Connect upload or submission (use `submit-appstore-release`).
---

# App Store intake

D-105 splits the App Store work by one rule: **what to show and how to say it is decided and made
in the App Store creative workspace; whether it is true and may ship is decided here, in the app.**
The workspace and its shared skill `appstore-creative` research, propose, let the user choose, draw
the faces and draft the copy. The app owns the facts (confirmed specs, `App Store/privacy/`,
`App Store/legal/`, `App Store/review/`, `App Store/submission/requirements.json`), the raw captures
and recordings, the intake, a copy of what was adopted, and every gate after it. Find the workspace
path in the registry `~/.agents/skills/.workspaces/registry.md`; this skill never names it.

The intake decides what may enter the app. It never edits a delivered file: a change is a new
delivery from the workspace.

## Before a delivery

1. Capture the raw images in the app, on the app's declared Simulators, with
   `tools/capture-appstore-screenshots.sh` under `tools/with-ios-simulator-lock.sh`, as in
   [`prepare-appstore-assets`](../prepare-appstore-assets/SKILL.md#phase-6-screenshot-routing). The launch
   arguments that put the app into each state must work in the build you capture; check every raw
   image before you hand the batch to the workspace.
2. Give the workspace session the batch folder and the app commit. The workspace reads the app's
   files and never writes into the app.

## Take a delivery in

The workspace session gives you a folder with `delivery.json` (schema 1, D-105) and `files/`. Run the
intake from the app's issue worktree, with a local clone of the workspace repository that contains the
delivered commit:

```sh
tools/intake-appstore-delivery.sh --delivery "$DELIVERY" --raw-root "$RAW_ROOT" \
  --requirements "App Store/submission/requirements.json" --bundle-id "$BUNDLE_ID" \
  --workspace-repo "$WORKSPACE_CLONE" --project-root "$PWD" --out "$COMPOSED_ROOT"
```

It refuses the whole delivery, and writes nothing, when any of these fails:

- `delivery.json` has the schema-1 keys and names this app's Bundle ID; every listed file has its
  SHA-256 and size, and no unlisted file is present;
- the raw capture `manifest.json` in `$RAW_ROOT` is the one the delivery was made from, matches its
  source SHA, build digest and runtime, and the current submission requirements, and every raw image
  still has its recorded bytes;
- every face is the tile its render record drew at its order, shows the raw capture of its locale,
  family and state, comes with its declaration, uses only materials `provenance.json` records as
  adopted, and is an RGB PNG of the family's size; every tile of every record is delivered;
- the user's choice exists in the workspace commit at the delivered path with the delivered SHA-256,
  is `user-explicit`, and matches the delivered sheet, time and pattern;
- delivered copy passes this app's `tools/check-store-copy.sh`.

On success `$COMPOSED_ROOT` holds the faces as `<locale>/<family>/NN-<state>.png`, byte copies of the
render records and `provenance.json` under `records/`, `composition.json` (the keys of D-101) and
`intake.json` (the workspace repository and commit, the delivery, renderer and choice SHA-256, the copy
check). In `composition.json`, `adoption.proposalSheetDigest` is the sheet the user chose on and
`adoption.selectionDigest` is the workspace's choice record.

Keep `$COMPOSED_ROOT` outside Git (for example under `.artifacts/`): the render records name the
workspace's local paths. Only the assembled set enters `App Store/screenshots/`.

## After the intake

- **Screenshots:** review both the raw captures and the composed faces, then assemble, validate and
  seal exactly as in [Composed screenshot sets](../prepare-appstore-assets/SKILL.md#composed-screenshot-sets-d-101),
  passing `--composition "$COMPOSED_ROOT/composition.json" --composed-root "$COMPOSED_ROOT"`. The
  review's `truthfulRepresentation` is the app's own check that each face shows the real app; the
  intake does not make it.
- **Copy:** write the delivered `copy/localizations/<locale>.yml` into
  `App Store/metadata/localizations/`, release notes into `App Store/release-notes/`, and the delivered
  decision summary into `App Store/metadata/aso-decisions.md`, in an app Issue. Saving to App Store
  Connect stays with `save-appstore-metadata` under its own approvals.
- Record the workspace repository, commit and case ID from `intake.json` in the app Issue.

## Never

- Draw, restyle, rewrite or choose in the app; ask the workspace for a new delivery instead.
- Take in faces drawn from raw images taken anywhere but the app's declared Simulators.
- Commit `$COMPOSED_ROOT`, render records, sheets or rejected images.
- Treat a passing intake as review, release-auditor approval, release readiness or permission to
  save, upload or submit.
