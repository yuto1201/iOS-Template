# Audio and speech modes

Consult the current official ElevenLabs API reference immediately before an authenticated request. These routes are capability selectors, not authorization to call them.

| Mode | Official operation | Required request inputs | Output and checks |
| --- | --- | --- | --- |
| `text-to-speech` | `POST /v1/text-to-speech/{voice_id}` | approved text, voice ID, model, language/pronunciation, output format | Audio; verify every spoken word, language, pacing, voice, silence, and clipping |
| `speech-to-speech` | `POST /v1/speech-to-speech/{voice_id}` (Voice Changer) | consented source audio, target voice ID, model, output format | Audio; compare content, timing, delivery, identity/consent, and artifacts. Split sources longer than the current provider limit rather than silently truncating |
| `speech-to-text` | `POST /v1/speech-to-text` | source audio/video, Scribe model, language or detection, diarization/event choices | JSON/text/captions; compare sampled timestamps, speakers, language, terms, and sensitive-data handling |
| `sound-effect` | `POST /v1/sound-generation` | English prompt, duration, loop flag, prompt influence, model | Audio; verify requested event, duration, loudness, and loop boundary |
| `audio-isolation` | `POST /v1/audio-isolation` | consented source audio/video and input format | Audio; compare speech preservation and removed background sound; do not describe it as general stem separation without evidence |
| `music` | `POST /v1/music` | original prompt or composition plan, duration, instrumental choice, model, output format | Audio; reject copyrighted artist/track imitation, verify musical brief, duration, loudness, loop, and license record |

Official references:

- Text to Speech: <https://elevenlabs.io/docs/api-reference/text-to-speech/convert>
- Voice Changer: <https://elevenlabs.io/docs/overview/capabilities/voice-changer>
- Speech to Text: <https://elevenlabs.io/docs/api-reference/speech-to-text/convert>
- Sound Effects: <https://elevenlabs.io/docs/api-reference/text-to-sound-effects/convert>
- Audio Isolation: <https://elevenlabs.io/docs/api-reference/audio-isolation/convert>
- Music: <https://elevenlabs.io/docs/api-reference/music/compose>

## Mode-specific stops

- For voice transformation, missing performer/source consent is `blocked:user`.
- For transcription or isolation, sensitive source retention that is not specified is `blocked:user`; do not upload first and decide later.
- A Music API plan failure is one `blocked:ops` result. Do not substitute Sound Effects for a requested song without changing the Issue acceptance criteria.
- A copyrighted-style rejection is not permission to evade the filter. Offer an original descriptive prompt for user approval.
- Do not claim full audio separation: the documented Audio Isolation route removes background noise to isolate speech and is not guaranteed to split arbitrary stems.

Use `templates/audio-manifest.yml` for every audio output and `templates/transcript-manifest.yml` for Speech to Text output.
