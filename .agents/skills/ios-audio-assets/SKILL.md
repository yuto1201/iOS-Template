---
name: ios-audio-assets
description: Generate and validate sound effects, jingles, or background music for an iOS app only when audio is an explicit Issue acceptance criterion. Use to prepare an ElevenLabs prompt, delegate authenticated generation to Codex, validate duration, format, hash, loudness and loop boundaries, or integrate a reviewed audio resource and sanitized manifest.
---

# iOS Audio Assets

Do not add an audio pipeline speculatively. Require an acceptance criterion that states the purpose, duration, destination, loop behavior, discontinuity threshold, and expected loudness.

## Workflow

1. Confirm the Issue requires audio and that the destination is inside the app feature's resource directory.
2. Prepare an English generation prompt, model choice, requested duration, loop flag, and license note. Claude may prepare these local inputs but must not authenticate or generate.
3. Have Codex resolve the installed `generating-elevenlabs-audio` skill:

```sh
.agents/skills/ios-audio-assets/scripts/check-elevenlabs-capability.sh \
  --capability sound-effect \
  --provider-status available
```

The `elevenlabs` CLI has no sound-effect or music generation subcommand. Invoke the resolved Codex-visible skill procedure; do not invent a CLI route. Keep the API key in the repository Keychain namespace and inject it only for the generation child process.
4. Before generation, have Codex verify the personal ElevenLabs account/workspace and exact `elevenlabs.generate_audio` operation through `tools/provider-preflight.sh`.
5. Generate once into a private scratch directory. If Music returns `paid_plan_required`, record one `blocked:ops` result with `retry: false`; do not retry or change plans automatically.
6. Move only the accepted asset into the repository resource destination and fill `templates/audio-manifest.yml` with the prompt, model, measured duration, loop contract, license note, hash, and date. Never record an API key or raw provider response.
7. Validate before integration:

```sh
.agents/skills/ios-audio-assets/scripts/validate-audio.sh \
  --root "$PWD" \
  --manifest path/to/audio-manifest.yml
```

8. Listen for artifacts, compare loudness to the Issue target, and review the loop boundary. Commit the accepted audio file and manifest together.

Authenticated ElevenLabs calls are Codex-only. Claude may inspect local audio with `afinfo`, edit the manifest, and integrate the validated resource.
