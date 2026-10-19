---
name: app-icon
description: Generate, select, validate, and integrate a simple iOS app icon after a new app's product direction and Identity are confirmed.
---

# App Icon

Use this after the app purpose, audience, product direction, display name, module name, app slug, Bundle ID, and Deployment Target are confirmed and Identity bootstrap is complete. Create a separate App Icon Issue that depends on Identity bootstrap and complete it before the first user-facing UI `shape`. Independent non-UI work may continue.

An app-icon selection does not satisfy the UI Direction Gate and must not approve or bypass navigation, information hierarchy, screen states, or primary-flow interaction. The App Icon Issue is a visual but structurally neutral `shape` with a `bounded direction-neutral` declaration, `standard` profile, and `iphone-ja` scope unless its approved contract requires a stricter route.

## Confirmed brief

Before generation, derive one short brief from confirmed app-specific specifications. Include the display name, purpose, audience, core benefit, emotional tone, preferred or excluded colors, and one or two suitable visual metaphors. If one of these would change acceptance and is unresolved, stop as `blocked:user`; do not make branding policy by guesswork.

Check the current Apple app-icon guidance linked from [`docs/references.md`](../../../docs/references.md) immediately before generation. Treat it as the authority for current dimensions, masking, appearance, and asset-catalog behavior.

## Generate and select

1. Use the default built-in image generation skill/tool. Do not substitute SVG, HTML, SF Symbols, a screenshot, or a manually drawn placeholder when the requested deliverable is an image-generated bitmap.
2. Create exactly two stable-ID candidates in separate built-in image-generation calls from the same confirmed brief. Keep their finish and constraints equal, but make their core visual metaphors meaningfully distinct.
3. Default each prompt to one centered recognizable subject, a simple solid or restrained gradient background, few shapes, few colors, strong small-size contrast, and no text, initials, numbers, screenshots, Apple hardware replicas, third-party marks, watermarks, baked rounded-corner mask, or fine detail. Ask for a square, full-bleed, opaque 1024 x 1024 PNG that remains legible after system masking.
4. Copy both candidates from the image-generation output location into a new immutable local revision under `.artifacts/app-icon/<revision>/`; do not reference a project asset only from the generator's default storage. Record the exact prompt and SHA-256 beside each local candidate without credentials or personal data.
5. Present both candidates with their stable concept IDs. Accept only one explicit concept selection. If the user requests a combination or any material change, generate a new immutable revision and ask for one explicit selection; never overwrite a shown candidate or silently create a hybrid.

Rejected and preselection candidates remain ignored decision-support artifacts. Do not commit them. The selected image becomes the only product asset.

### Reference-image edits

Use a user-provided image as an image-generation edit input only after the user explicitly confirms they hold the rights to use it for the app icon. Keep the reference image outside Git, either outside the repository or in an ignored path such as `.artifacts/app-icon/`. The accepted record keeps only the reference SHA-256 and the `builtin-imagegen-reference-edit` generation mode. The edited result keeps the default constraints above: no text, third-party marks, identifiable human faces, watermarks, or baked masks. Never install the reference image itself as the icon.

## Integrate

From the clean nondefault Branch/worktree for the App Icon Issue, save the selected prompt summary in a regular local file and run:

```sh
tools/install-app-icon.sh \
  --root "$PWD" \
  --source "/absolute/path/to/selected-concept.png" \
  --concept-id "concept-a" \
  --prompt-file "/absolute/path/to/selected-prompt.txt" \
  --generator builtin-imagegen
```

The installer requires `Config/app-identity.json`, derives the module path instead of accepting one from the caller, rejects actual transparency or wrong dimensions, normalizes an all-opaque alpha channel to an opaque PNG, preserves optional dark/tinted asset-catalog entries, writes `Config/app-icon.json`, and refuses conflicting reruns. Inspect the complete diff, then run:

```sh
tools/validate-app-icon.sh --root "$PWD"
```

Open the selected source at full size and deterministic 60 px and 29 px previews for visual inspection. Confirm that the subject remains recognizable, centered, unclipped, simple, free of accidental text or watermarking, and visually compatible with system masking. Then Build and run the App Icon Issue's current-Head `iphone-ja` verification. Custom dark/tinted variants and complete release checks remain separate only when the app's confirmed requirements need them.

Commit the selected PNG, `Contents.json`, and `Config/app-icon.json` together. Keep rejected generations, raw provider responses, and local preview files outside Git.
For a reference-image edit, replace the generator with `builtin-imagegen-reference-edit` and add `--reference-image "/absolute/path/outside-git.png" --reference-rights user-confirmed`.

## Replace an accepted icon

Replace an accepted icon for a later release only through its own replacement Issue, separate from the initial App Icon Issue. Updating an icon published elsewhere, such as a Web-AppLibrary listing or App Store Connect, is a separate handoff Issue.

1. Generate candidates for a new immutable revision under `.artifacts/app-icon/<revision>/` as described in Generate and select. Never reuse a revision that produced the current or any earlier accepted icon.
2. After the user explicitly selects one stable concept ID, write `selection.json` beside those candidates. List each shown candidate with the SHA-256 of its local bytes:

```json
{"schemaVersion":1,"revision":"<revision>","candidates":[{"conceptId":"concept-c","sha256":"sha256:<candidate bytes>"}],"selectedConceptId":"concept-c","selection":"user-explicit"}
```

3. From the clean nondefault replacement Branch/worktree, copy the accepted `sha256` from `Config/app-icon.json` and run:

```sh
tools/install-app-icon.sh \
  --root "$PWD" \
  --source "/absolute/path/.artifacts/app-icon/<revision>/concept-c.png" \
  --concept-id "concept-c" \
  --prompt-file "/absolute/path/to/selected-prompt.txt" \
  --generator builtin-imagegen \
  --replace-accepted "sha256:<current accepted digest>" \
  --selection "/absolute/path/.artifacts/app-icon/<revision>/selection.json"
```

The installer first validates the accepted icon. Before changing any file, it refuses a declared digest that differs from the current record, a selection that is not `user-explicit`, a source that is not the selected candidate stored in that revision, an unchanged icon, a selection revision that any committed version of `Config/app-icon.json` already accepted, and a dirty worktree. The resulting schema 2 record keeps the new accepted values, `selectionRevision`, and `supersedes` with the previous concept ID, generator, and SHA-256; Git history keeps earlier records. Rerunning the same replacement reports `already-complete`. Then validate, inspect the previews, verify, and commit the replaced PNG and record as in Integrate.

### Replace with a finished icon the user provides

D-083 adds one exception to the replacement above. When the user hands over a finished icon image and explicitly says to use it as it is, replace the accepted icon with it without generating candidates. The first icon of a new app still comes from the generated candidates (D-031).

1. Confirm in the conversation that the user holds the rights to use the image as the app icon, and record that confirmation on the replacement Issue.
2. Check the image as for a generated one: a square opaque 1024 x 1024 PNG before the system mask, with no text, initials, numbers, screenshots, copies of Apple products, third-party marks, identifiable human faces, watermarks, or baked masks. The simple-composition defaults (one subject, a plain background, few shapes and colors) do not apply to a finished icon.
3. Store the original outside Git in a new revision folder, such as `.artifacts/app-icon/<revision>/`. A dark appearance image the user provides stays in the app's existing dark entry; the installer leaves the dark and tinted entries untouched.
4. Write the provenance and the date of the rights confirmation, without secrets, to the prompt file, and run:

```sh
tools/install-app-icon.sh \
  --root "$PWD" \
  --source "/absolute/path/.artifacts/app-icon/<revision>/<image>.png" \
  --concept-id "user-<revision>" \
  --prompt-file "/absolute/path/to/provenance.txt" \
  --generator user-provided \
  --provided-rights user-confirmed \
  --replace-accepted "sha256:<current accepted digest>" \
  --revision "<revision>"
```

The installer refuses a missing or other rights value, a first install, a candidate selection or reference image, a source outside its revision folder, a tracked original, and every condition of the replacement above. The schema 2 record has `generator: "user-provided"`, `referenceSha256: null` (the asset is the user's image written as an opaque PNG, with no other edit input), `selectionRevision`, and `supersedes`. Then validate, inspect the previews, verify, and commit as in Integrate.
