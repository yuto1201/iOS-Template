# Image and video modes

ElevenLabs Image & Video is asynchronous and may use third-party models. API access, model availability, permissions, regional availability, and plan requirements must be checked immediately before submission.

| Mode | Official operation | Required request inputs | Output and checks |
| --- | --- | --- | --- |
| `image` | `POST /v1/flows/image` through the current SDK/API schema | original prompt, model, aspect ratio/resolution, optional rights-cleared references | PNG; verify exact dimensions, transparency/color needs, text/logos, artifacts, and app-context appearance |
| `video` | `POST /v1/flows/video` through the current SDK/API schema | original prompt, model, duration, aspect ratio/resolution, audio flag, optional rights-cleared frames/media | MP4; verify dimensions, duration, motion continuity, unwanted audio/text/logos, and app playback |

Official references:

- Image & Video quickstart: <https://elevenlabs.io/docs/eleven-api/guides/cookbooks/image-and-video>
- Capability and plan overview: <https://elevenlabs.io/docs/overview/capabilities/image-video>
- Reference assets: <https://elevenlabs.io/docs/eleven-api/guides/how-to/image-and-video/references>
- Webhooks: <https://elevenlabs.io/docs/eleven-api/guides/how-to/image-and-video/webhooks>

## Asynchronous collection

- Prefer an existing verified HTTPS webhook subscribed to generation events. Verify its HMAC signature before trusting a result.
- If no webhook exists, poll images no faster than the current documented minimum interval and videos at the longer documented interval. Back off and enforce a finite deadline.
- A timeout with unknown provider state is ambiguous. Keep its generation ID, stop, and inspect that exact generation later; do not submit a replacement automatically.
- Download a completed signed URL promptly into private scratch space. Validate MIME type and bytes rather than trusting the URL suffix.
- Persistent reference uploads are external provider data. Reuse them only when the Issue permits provider retention; otherwise prefer supported inline input and do not create a retained asset.

## Rights and product checks

- Do not upload faces, brands, private screenshots, copyrighted characters, or third-party reference media without a documented right and purpose.
- Do not automatically enable restricted models or change the subscription. `paid_plan_required`, `model_access_denied`, moderation, and regional restrictions stop the attempt.
- Generated visuals still require app-specific accessibility, localization, privacy, App Store, and human/AI visual review. Generation success is not integration approval.

Use `templates/visual-manifest.yml` for an accepted PNG or MP4 output.
