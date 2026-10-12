# Generated images

Use Codex's built-in image generation (the `image_gen` tool of its `imagegen` skill).
It needs no API key. Generated images are material: backgrounds, settings, wide
strips and concept art. They never replace a real screen.

## Who generates

- **Codex** calls its built-in image generation directly, one call per image.
- **Claude** asks Codex to generate and nothing else, from a scratch directory:

  ```sh
  codex exec --skip-git-repo-check -C "$WORK" -s workspace-write \
    "Use your built-in image generation tool (not SVG, not code, not the CLI fallback) to create ONE image: <prompt>. Request a tall portrait size as close as possible to a 1206x2622 aspect ratio. Copy the generated PNG into the current directory as <name>.png, then print the source path and 'sips -g pixelWidth -g pixelHeight <name>.png'. Do nothing else."
  ```

  For an edit (`scene`), attach the reference with `-i render.png` and say what must
  stay unchanged. Read the session id from the first log lines if a follow-up is
  needed, and resume only that id, never `--last`.
- If built-in generation fails or is unavailable, stop and report it. The CLI
  fallback needs an API key; use it only when the user explicitly asks for it.

## Prompts

Describe the subject, mood, light and colors from the brief. Always add: no text, no
letters or numbers, no logos or watermarks, no app screens or user interface, no
recognizable Apple hardware, no identifiable faces. Hands may appear. Never ask for
an image of the app itself; the device and its screen come from real captures.

## Size

A tall portrait request returned 851×1849 on 2026-10-12, within 0.1% of the aspect
ratio of the 1206×2622 iPhone tile (D-079). Scale generated material to the exact tile
size before use, for example `sips -z 2622 1206 in.png --out out.png`, and inspect it for softness.
For iPad (2064×2752) or a `continuous` strip, ask for that aspect ratio and keep the
subject inside the area every device crop keeps. Scaling and cropping are allowed for
generated material only, never for real captures.

## Keep and record

1. Copy each result from Codex's `generated_images` folder into
   `.artifacts/store-creative/<revision>/generated/`. Never reference an image only
   from Codex's own folder.
2. Write the prompt, the mode (`generate` or `edit`), the generator
   (`codex-builtin-imagegen`), the reference image's SHA-256 for an edit, the output's
   SHA-256 and the time beside it.
3. Look at every image before use: no text, logos, UI, faces, watermarks or broken
   anatomy, and it fits the brief. Generate again when it does not; stop and ask after
   two failures with the same cause.
4. When the user adopts a set, copy only the adopted images into `goldie/assets/` and
   list them in `goldie/assets/provenance.json` with the same fields and the revision.

Use a user's own reference image only after the user confirms they hold the rights
to use it; keep it outside Git and record only its SHA-256.
