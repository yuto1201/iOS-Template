# Runtime and configuration

## Install once

Run from the app repository (not an unbuilt Goldie source checkout):

```sh
GOLDIE_RUNTIME="${XDG_CACHE_HOME:-$HOME/.cache}/codex-goldie/0.3.1"
npm install --prefix "$GOLDIE_RUNTIME" --save-exact --no-audit --no-fund goldie@0.3.1
node "$GOLDIE_RUNTIME/node_modules/goldie/dist/cli.js" version
node "$GOLDIE_RUNTIME/node_modules/goldie/dist/cli.js" help
```

The top-level version is pinned; npm resolves transitive dependencies into this
runtime's package-lock.json. Retain that lock and use `npm ci --prefix
"$GOLDIE_RUNTIME"` to recreate the same runtime. Don't share/overwrite another
project's Node dependencies. If the runtime already exists, inspect version/lock
before changing it. For a new machine, copy the adapted skill directory into
`~/.codex/skills/goldie` only when that destination does not already exist.

## Starter config

Copy `assets/goldie.config.ts` (relative to this skill) into a new
`goldie/ja/` directory, and another copy into `goldie/en-US/` when needed. Preserve
existing config. Run each locale separately; generated `out/` sits beside its config.

Every invocation needs these values, derived from the actual app:

```sh
GOLDIE_APP_ROOT="$PWD" \
GOLDIE_APP_PATH="/absolute/path/to/owned/Release-iphonesimulator/App.app" \
GOLDIE_BUNDLE_ID="com.example.actualapp" \
GOLDIE_LOCALE="ja" \
GOLDIE_CONFIG="$PWD/goldie/ja/goldie.config.ts" \
node "$GOLDIE_RUNTIME/node_modules/goldie/dist/cli.js" doctor
```

`GOLDIE_APP_*`, `GOLDIE_BUNDLE_ID`, and `GOLDIE_LOCALE` are **our starter's** inputs,
not built-in Goldie flags. `GOLDIE_CONFIG` is supported by Goldie. Replace every
example value before a real capture. Use arguments/environment at runtime instead
of committing machine-specific paths. The starter is screenshot-only, with one
scene to replace/extend; it is not a finished store design.

To test config loading without touching Simulator state or creating images:

```sh
# Set the same environment inputs first. This only imports the configuration.
GOLDIE_RUNTIME="$GOLDIE_RUNTIME" node --input-type=module - <<'JS'
import { pathToFileURL } from 'node:url';
const {loadConfig} = await import(pathToFileURL(
  `${process.env.GOLDIE_RUNTIME}/node_modules/goldie/dist/index.js`));
const cfg = await loadConfig(process.env.GOLDIE_CONFIG);
if (cfg.devices.join() !== 'iphone-6.9' || cfg.locales.length !== 1)
  throw new Error('Expected one iPhone device and one locale');
console.log(JSON.stringify({devices:cfg.devices, locales:cfg.locales,
  scenes:cfg.scenes.map(s=>s.id), outDir:cfg.outDir}));
JS
```

`loadConfig` is a syntax/layout check, not proof the app exists or the flows work.
`doctor` checks dependencies and flow-file presence; it may start Argent's local
server. In setup-only mode prefer the config loader. No successful doctor result
proves safe device ownership or end-to-end capture.

## Import existing captures

Keep source originals outside Goldie's disposable `out/`. The actual screenshot
must already be a 1320×2868 iPhone capture with verified locale. Read it visually
and check dimensions before copying; no stretching. Write
`goldie/<locale>/out/raw/iphone-6.9/manifest.json` using this 0.3.1 shape:

```json
{
  "device": "iphone-6.9",
  "udid": "ACTUAL_SOURCE_SIMULATOR_UDID",
  "capturedAt": "ACTUAL_SOURCE_CAPTURE_TIMESTAMP",
  "screenshots": [
    {"sceneId": "home", "file": "/absolute/path/to/copied/home.png"}
  ],
  "preview": null
}
```

Use values from the real capture record; do not populate example metadata as fact.
For user-supplied images without capture metadata, keep `udid` and `capturedAt`
empty strings and a companion `provenance.json` stating `user-supplied`, original
path, SHA-256, known locale and metadata gaps. This is only an input for rendering,
never a release capture receipt. `file` should be an absolute path; match each
`sceneId` exactly to the config. Import separate source images for each locale.
Do not run `capture` when the task is only decorating existing images.

Then, with the same environment inputs, run:

```sh
node "$GOLDIE_RUNTIME/node_modules/goldie/dist/cli.js" frame
node "$GOLDIE_RUNTIME/node_modules/goldie/dist/cli.js" manifest
node "$GOLDIE_RUNTIME/node_modules/goldie/dist/cli.js" verify
node "$GOLDIE_RUNTIME/node_modules/goldie/dist/cli.js" studio --no-open --port 4321
```

Check the port first and choose another if occupied. `frame` deletes/replaces PNGs
in its output screenshot directory; archive an existing candidate before editing.
Keep Studio changes in `goldie.design.json`, which overrides config fields; don't
claim a config edit took effect without checking those overrides. A stable result
can retain both tracked files, or move the chosen values into config and explicitly
remove only the now-redundant overrides.

Layouts include classic, hero, offset, tilt, minimal, duo and panorama. Start with
classic/hero; duo needs a second real capture and panorama consumes two store slots.
See the pinned [upstream config reference](https://github.com/kacperkapusciak/goldie/blob/788dd6ec4c8d5ed4d7647135ba4239fa397ccecd/skills/goldie/references/config.md)
for supported layout/decorations fields. Avoid absolute type imports from a
particular developer's checkout; the supplied config uses erased `import type`
from the published `goldie` package.
