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

## Style spec format and quality bar (D-085)

The style spec format ([proposal](proposal.md#style-spec-one-per-pattern)) and the
[quality bar](patterns.md#quality-bar) are adapted from
[ParthJadhav/app-store-screenshots](https://github.com/ParthJadhav/app-store-screenshots)
(`skills/app-store-screenshots/style-prompts/` and `_QUALITY_BAR.md`, inspected
2026-10-21). Its code, Next.js editor and the text of its eighteen named styles are not
included; the numbers of the quality bar are restated as proportions of the App Store
tile. The techniques list draws on the before.click gallery and the ShotStudio template
library, inspected the same day; nothing from either is copied. The adapted parts are
used under this license:

```text
MIT License

Copyright (c) 2026 Parth Jadhav

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

Before upgrading, inspect package version, upstream license, config schema, locale
capture behavior, device selection, output cleanup behavior and Apple rule changes.
Re-run version/help and both starter locales. Only claim capture/render parity after
actually verifying those operations on owned demo data. Preserve each runtime's
lockfile and record the new resolved dependency versions.
