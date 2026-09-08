# Upstream and updates

Adapted from [kacperkapusciak/goldie](https://github.com/kacperkapusciak/goldie),
commit `788dd6ec4c8d5ed4d7647135ba4239fa397ccecd`, inspected 2026-09-08.
CLI baseline: npm `goldie@0.3.1`.

The upstream skill already supports Codex's SKILL.md format. This adaptation adds
Japanese discovery, portable published-package usage, setup-only/capture/video
scope, separate per-locale raw output, existing-image import and iOS-Template
handoff. It does not fork the CLI or claim to be maintained by the upstream author.

Code and skill documentation are MIT licensed; retain [LICENSE](../LICENSE).
Bundled iPhone bezel artwork is derived from Kelly Hu's
[iPhone 17 & 17 Pro Device Frames](https://www.figma.com/community/file/1600584030566600974/iphone-17-17-pro-device-frames),
CC BY 4.0. Bundled fonts are SIL OFL 1.1. Keep the npm package's
`assets/ATTRIBUTION.md` and relevant license files with distributed framed assets;
using a bezel-free layout avoids using that device artwork. No frame/font binaries
are vendored into this template skill.

Before upgrading, inspect package version, upstream license, config schema, locale
capture behavior, device selection, output cleanup behavior and Apple rule changes.
Re-run version/help and both starter locales. Only claim capture/render parity after
actually verifying those operations on owned demo data. Preserve each runtime's
lockfile and record the new resolved dependency versions.
