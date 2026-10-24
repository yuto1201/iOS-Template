---
name: ios-design-2d-asset
description: Use when an approved Issue requires creating or structurally changing a 2D animation, motion graphic, or bundled video inside the iOS app (SwiftUI choreography, a Remotion-rendered clip, a Rive file, or an ElevenLabs video); this repository adapter keeps the gates and defers the authoring procedures to the shared Mac skill design-2d-asset (D-090). Not for App Store screenshots or preview videos (use appstore-creative), websites, still images (use ios-design-image-asset), or 3D (use ios-3d-assets).
---

# iOS 2D Assets

Use this skill when an approved Issue requires creating or structurally changing a 2D animation, a motion graphic, or a video bundled in the app. Do not invoke it for App Store screenshots or preview videos (use `appstore-creative`), for website motion, for still images (use `ios-design-image-asset`), or for 3D models and 3D animation (use `ios-3d-assets`).

## Shared authoring skill

This skill is the repository adapter. The authoring procedures (choosing the tool, SwiftUI choreography, Remotion rendering, Rive files, ElevenLabs video) live in the shared Mac skill `design-2d-asset` at `~/.agents/skills/design-2d-asset/`, which Claude and Codex both read. In this repository, this adapter, D-090, and `AGENTS.md` take precedence over the shared skill.

When the shared skill cannot be read in the current environment, stop as `blocked:environment` before authoring. Do not reconstruct its procedures from memory.

## Route and contract

Choose one route per asset revision and record it in the Issue/PR evidence as `swiftui`, `remotion`, `rive`, or `elevenlabs`. Before authoring, write the choreography (what happens at which second) in the Issue, the screens and states that show the motion, and the finished still pose used when motion is reduced. Unresolved choices that change the expected motion are `blocked:user`.

## Gates

- Reduce Motion: when the system setting is on, show the finished still pose instead of the animation.
- Dark appearance: check the motion in Light and Dark appearance; outline line art that would disappear on a dark background.
- VoiceOver: hide decorative motion from VoiceOver and give a loading or status animation a spoken label.
- Performance: run a continuous animation (for example `TimelineView(.animation)`) only while it is on screen, and never extend loading or launch time to show an animation.
- Rive: adding the `RiveRuntime` Swift package changes the Xcode project and needs the user's approval in the Issue before it is added; a production `.riv` without the Rive splash needs a paid Rive plan, which the user decides. Record both approvals.
- Bundled video: the Issue states the maximum file size and duration, whether Light and Dark versions are needed, and whether the clip loops. Validate every accepted MP4 with `.agents/skills/ios-media-assets/scripts/validate-visual.sh` and a `video` manifest from `.agents/skills/ios-media-assets/templates/visual-manifest.yml`.
- ElevenLabs video: check the route with `.agents/skills/ios-media-assets/scripts/check-elevenlabs-capability.sh --capability video`, verify the configured account with `tools/provider-preflight.sh` before submitting, and pass the API key only to the child process through `tools/run-with-secret.sh`. A plan, permission, moderation, or ambiguous failure returns one `blocked:ops` or `blocked:user` result with `retry: false`.

## Verification and evidence

Verify the integrated motion through the normal `ios-verify` and opposite-model review gates for the Issue's stage. A Simulator recording or a contact sheet helps the review but does not replace canonical evidence.

Record the route, the tool and its version, the choreography, the clip size and duration, and the approvals. Do not record credentials or account details. Keep experiments, rejected renders, and provider responses outside Git; commit only the accepted source or asset and its manifest.
