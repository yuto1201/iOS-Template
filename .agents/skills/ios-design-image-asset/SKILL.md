---
name: ios-design-image-asset
description: Use when an approved Issue requires a still image to enter the iOS app (an illustration, background, texture, sprite, or decorative image); this repository adapter keeps the contract, validation, and evidence and defers the authoring procedures to the shared Mac skill design-image-asset (D-090). Not for the required new-app icon (use app-icon), App Store screenshots (use appstore-creative), 2D animation (use ios-design-2d-asset), or 3D (use ios-3d-assets).
---

# iOS Image Assets

Use this skill when an approved Issue requires a still image to enter the app. Do not route the required new-app icon through this skill; use [`app-icon`](../app-icon/SKILL.md). App Store screenshots use `appstore-creative`, 2D animation uses `ios-design-2d-asset`, and 3D uses `ios-3d-assets`.

## Shared authoring skill

This skill is the repository adapter. The authoring procedures (choosing the route, the Codex brief and evaluation rounds, styles such as low-poly, simple vector graphics, ElevenLabs images) live in the shared Mac skill `design-image-asset` at `~/.agents/skills/design-image-asset/`, which Claude and Codex both read. In this repository, this adapter, D-090, and `AGENTS.md` take precedence over the shared skill.

When the shared skill cannot be read in the current environment, stop as `blocked:environment` before authoring. Do not reconstruct its procedures from memory.

## Route

Choose one route per image revision and record it in the Issue/PR evidence as `codex`, `vector`, or `elevenlabs`. The `codex` route uses Codex's built-in `image_gen` as the shared skill describes, and the style (for example low-poly) is written in the brief, not chosen as a route; never switch to the CLI path or another model unless the user asks for it. The `elevenlabs` route also checks `.agents/skills/ios-media-assets/scripts/check-elevenlabs-capability.sh --capability image`, runs `tools/provider-preflight.sh`, and passes the key only through `tools/run-with-secret.sh`.

## Contract

Before authoring, the Issue states the purpose, the destination (asset catalog name or resource path), the size and scale factors, transparency, whether Light and Dark versions are needed, the maximum file size, and the rights basis for every reference image. Never draw text into the image; put text in the interface so it can be localized. Hide a decorative image from VoiceOver and give a meaningful image a spoken label. Unresolved choices that change the expected image are `blocked:user`. Do not use real people, brands, or other companies' characters without a documented right.

## Validation

Validate every accepted raster image as a PNG with `.agents/skills/ios-media-assets/scripts/validate-visual.sh` and an `image` manifest from `.agents/skills/ios-media-assets/templates/visual-manifest.yml`; record the route and the rights basis in its `model` and `licenseNote`. A vector asset is exported to PNG for that check, or the Issue names its own check. Then verify the image in the app in Light and Dark appearance through `ios-verify` and the opposite-model review gates for the Issue's stage.

## Evidence and boundary

Record the route, the model, the prompts or reference descriptions, the number of rounds, and the rights basis. Do not record credentials or account details. Keep rejected images, intermediate files, and provider responses outside Git; commit only the accepted image and its manifest.
