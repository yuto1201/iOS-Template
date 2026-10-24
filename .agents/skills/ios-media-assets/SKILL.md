---
name: ios-media-assets
description: Create or transform iOS app speech, transcripts, sound effects, isolated audio, music, general images, or videos with ElevenLabs when an approved Issue explicitly requires a media asset; use app-icon for the required new-app icon. This repository adapter defers the provider API details to the shared Mac skill elevenlabs-media.
---

# iOS Media Assets

Use ElevenLabs to fill media-production gaps that Codex or Claude cannot satisfy locally. Keep the integration dormant until an approved Issue makes one media output an acceptance criterion; never add the ElevenLabs SDK to the app merely to generate development assets.

Do not route the required new-app icon through this skill. Use [`app-icon`](../app-icon/SKILL.md) and built-in image generation so creating an app icon does not activate an ElevenLabs account, entitlement, SDK, or provider dependency.

## Shared provider skill

This skill is the repository adapter. The provider details (each mode's API operation and request inputs, the official references, asynchronous image and video collection, and the `elevenlabs` CLI's limits) live in the shared Mac skill `elevenlabs-media` at `~/.agents/skills/elevenlabs-media/`, which Claude and Codex both read. In this repository, this adapter and D-023 take precedence over the shared skill: the gates, secret handling, and validation below apply to every mode.

When the shared skill cannot be read in the current environment, stop as `blocked:environment` before any external work. Do not reconstruct the provider API from memory.

## Route by mode

| Mode | Use for | Required local validation |
| --- | --- | --- |
| `text-to-speech` | Narration or character speech from approved copy | Audio manifest and listening review |
| `speech-to-speech` | Voice Changer transformation that preserves an approved performance | Source consent, audio manifest, and listening review |
| `speech-to-text` | Transcript, captions, or structured speech analysis | Transcript manifest and content review |
| `sound-effect` | UI feedback, ambience, Foley, or a jingle | Audio manifest, loudness, duration, and optional loop review |
| `audio-isolation` | Remove background sound from speech | Source rights, audio manifest, and before/after listening review |
| `music` | An approved music or BGM asset | Audio manifest, listening review, loop review, and license record |
| `image` | An approved static visual asset | Visual manifest, dimensions, transparency/color review, and in-app visual review |
| `video` | An approved motion asset | Visual manifest, duration/dimensions, playback review, and in-app visual review |

## Required contract

Before external work, confirm the Issue specifies the mode, purpose, destination, output format, acceptance checks, and maximum acceptable cost or plan boundary. Add the following when relevant:

- speech: exact approved text, language, voice ID, pronunciation, and consent or license basis;
- transformed or transcribed media: source path/digest, retention sensitivity, and rights to process it;
- audio: duration, loudness target, loop behavior, and discontinuity threshold;
- image/video: dimensions or aspect ratio, duration, reference-media rights, and whether generated audio is allowed.

If consent, ownership, privacy treatment, or an acceptance-affecting choice is unresolved, stop as `blocked:user`. Do not imitate a real person, clone or transform a voice, or upload third-party media without an explicit rights basis. Missing performer consent for voice transformation, or unspecified retention for a sensitive transcription or isolation source, is `blocked:user` before anything is uploaded.

## Repository workflow

1. Claude or Codex may prepare sanitized prompts, local source media, manifests, app integration, and authenticated ElevenLabs work after the same account-bound preflight.
2. The selected executor checks the route from the Issue worktree:

```sh
.agents/skills/ios-media-assets/scripts/check-elevenlabs-capability.sh \
  --capability MODE \
  --provider-status available
```

3. The selected executor verifies the configured account, workspace, and exact entitlement before submitting anything:

```sh
tools/provider-preflight.sh --executor EXECUTOR --issue ISSUE elevenlabs --operation MODE
```

4. Retrieve the API key only for the child process through `tools/run-with-secret.sh` and the Keychain name in `docs/security.md`. Never put it in Git, a prompt, argv, logs, Issue/PR text, manifests, or a persistent environment variable.
5. Make the request as the shared skill describes. Submit once into a private scratch directory and keep any non-secret provider generation ID only in local evidence.
6. Do not automatically retry `paid_plan_required`, permission denial, moderation, copyright rejection, or an ambiguous request that may already have been charged. Return one `blocked:ops` or `blocked:user` result with `retry: false`. Never change the user's plan or enable a provider model automatically. Do not substitute Sound Effects for a requested song without changing the Issue acceptance criteria.
7. Inspect the output before repository integration. Reject silence, clipping, mistranscription, wrong language/voice, visible artifacts, unwanted text/logos, unsafe references, or a result outside the Issue contract.
8. Move only the accepted output and its sanitized manifest into the feature's resource directory. Validate it with the matching script:

```sh
.agents/skills/ios-media-assets/scripts/validate-audio.sh --root "$PWD" --manifest path/to/audio-manifest.yml
.agents/skills/ios-media-assets/scripts/validate-transcript.sh --root "$PWD" --manifest path/to/transcript-manifest.yml
.agents/skills/ios-media-assets/scripts/validate-visual.sh --root "$PWD" --manifest path/to/visual-manifest.yml
```

Use `templates/audio-manifest.yml` for every audio output, `templates/transcript-manifest.yml` for Speech to Text output, and `templates/visual-manifest.yml` for an accepted PNG or MP4 output.

9. Integrate and verify the asset through the normal `ios-verify` and opposite-model review gates. Commit the accepted asset and manifest together. Keep rejected generations, raw provider responses, sensitive sources, and temporary signed URLs outside the repository.

ElevenLabs features, model availability, permissions, retention, and pricing can change. Treat the current entitlement response and official documentation checked at execution time as authoritative; this adapter defines routing and safety, not a permanent plan promise.
