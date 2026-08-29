---
name: ios-media-assets
description: Create or transform iOS app speech, transcripts, sound effects, isolated audio, music, images, or videos with ElevenLabs when an approved Issue explicitly requires a media asset.
---

# iOS Media Assets

Use ElevenLabs to fill media-production gaps that Codex or Claude cannot satisfy locally. Keep the integration dormant until an approved Issue makes one media output an acceptance criterion; never add the ElevenLabs SDK to the app merely to generate development assets.

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

Read [audio and speech modes](references/audio-and-speech.md) only for the first six modes. Read [image and video modes](references/image-and-video.md) only for visual generation.

## Required contract

Before external work, confirm the Issue specifies the mode, purpose, destination, output format, acceptance checks, and maximum acceptable cost or plan boundary. Add the following when relevant:

- speech: exact approved text, language, voice ID, pronunciation, and consent or license basis;
- transformed or transcribed media: source path/digest, retention sensitivity, and rights to process it;
- audio: duration, loudness target, loop behavior, and discontinuity threshold;
- image/video: dimensions or aspect ratio, duration, reference-media rights, and whether generated audio is allowed.

If consent, ownership, privacy treatment, or an acceptance-affecting choice is unresolved, stop as `blocked:user`. Do not imitate a real person, clone or transform a voice, or upload third-party media without an explicit rights basis.

## Shared workflow

1. Claude or Codex may prepare sanitized prompts, local source media, manifests, and app integration. Authenticated ElevenLabs inspection, upload, generation, transformation, transcription, polling, and download are Codex-only.
2. Codex checks the selected route from the Issue worktree. Claude delegates this named check rather than invoking a path blocked by its external-operation guard:

```sh
.agents/skills/ios-media-assets/scripts/check-elevenlabs-capability.sh \
  --capability MODE \
  --provider-status available
```

3. Codex verifies the configured personal account, workspace, and exact entitlement before submitting anything:

```sh
tools/provider-preflight.sh --issue ISSUE elevenlabs --operation MODE
```

4. Retrieve the API key only for the child process through the repository secret tooling. Never put it in Git, a prompt, argv, logs, Issue/PR text, manifests, or a persistent environment variable. The installed `elevenlabs` CLI manages authentication and agents; media operations may require the official API or SDK because the CLI does not expose every mode.
5. Submit once into a private scratch directory. For asynchronous image/video work, prefer a verified webhook; bounded polling is allowed when no endpoint exists. Preserve a non-secret provider generation ID only in local evidence until the signed result is downloaded.
6. Do not automatically retry `paid_plan_required`, permission denial, moderation, copyright rejection, or an ambiguous request that may already have been charged. Return one `blocked:ops` or `blocked:user` result with `retry: false`. Never change the user's plan or enable a provider model automatically.
7. Inspect the output before repository integration. Reject silence, clipping, mistranscription, wrong language/voice, visible artifacts, unwanted text/logos, unsafe references, or a result outside the Issue contract.
8. Move only the accepted output and its sanitized manifest into the feature's resource directory. Validate it with the matching script:

```sh
.agents/skills/ios-media-assets/scripts/validate-audio.sh --root "$PWD" --manifest path/to/audio-manifest.yml
.agents/skills/ios-media-assets/scripts/validate-transcript.sh --root "$PWD" --manifest path/to/transcript-manifest.yml
.agents/skills/ios-media-assets/scripts/validate-visual.sh --root "$PWD" --manifest path/to/visual-manifest.yml
```

9. Integrate and verify the asset through the normal `ios-verify` and opposite-model review gates. Commit the accepted asset and manifest together. Keep rejected generations, raw provider responses, sensitive sources, and temporary signed URLs outside the repository.

ElevenLabs features, model availability, permissions, retention, and pricing can change. Treat the current entitlement response and official documentation checked at execution time as authoritative; the references in this skill define routing and safety, not a permanent plan promise.
