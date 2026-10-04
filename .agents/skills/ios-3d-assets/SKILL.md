---
name: ios-3d-assets
description: Route iOS 3D model, mesh, material, rig, or animation authoring through Tripo in the browser by default, or to Claude or Codex gpt-6-astra (xhigh) for simple or quick models, while Claude or Codex integrate and verify accepted assets.
---

# iOS 3D Assets

Use this skill when an approved Issue requires creating, generating, or structurally revising a 3D model, mesh, material, rig, or animation. Do not invoke it merely because existing 3D bytes are being copied, integrated, or deterministically validated.

## Authoring routes (D-071)

Choose one route per asset revision and record it in the Issue/PR evidence as `tripo`, `claude`, or `gpt-6-astra`. The Issue names the route; when it does not, use the standard Tripo route, and leave the final choice to the user.

### Standard route: Tripo in the browser

- The user or Claude creates the model by operating Tripo in the browser.
- The user signs in, changes the plan or billing, and enters any credentials. Claude never types a password, payment detail, or token, never buys credits, never changes account settings, and never accepts terms on the user's behalf.
- Claude works only inside the user's already signed-in session, and only submits generation requests and downloads the accepted result. Ask the user before a generation that spends paid credits beyond what they approved for the Issue, and before each download.
- Before committing a Tripo output to an app that will ship, confirm with the user that their Tripo plan permits that commercial use.
- Record the route, the generation date, the prompt or reference description, and the export format. Do not record account identifiers, session data, or billing details.

### Quick route: Claude or Codex `gpt-6-astra`

- For a simple model or when speed matters, ask Claude, or Codex running the exact model `gpt-6-astra` with reasoning effort `xhigh`.
- Either may use local tools such as Blender scripting or format converters inside the Issue scope.
- A Codex handoff names `gpt-6-astra` and `xhigh` explicitly; record the actual model in the evidence.

Claude and Codex retain equal authority for general development. Either may prepare confirmed requirements and references, integrate an accepted asset, implement RealityKit behavior, run Blender or platform validators, Build/Test the app, inspect rendered output, or review the result.

## Authoring boundary

Before authoring, specify the intended object, scale and coordinate conventions, topology or polygon budget, materials and textures, rig/animation requirements, target formats, visual references and rights, and acceptance views. Unresolved choices that change the expected asset are `blocked:user`.

Stay inside the Issue scope and preserve source files needed for reproducibility. After authoring, the owning Issue validates every required source and export independently, whatever the route. For Apple integration, treat GLB validation, USDZ validation, ARKit compatibility checks, RealityKit loading, animation playback, and physical-device behavior as separate claims; do not infer one from another.

Commit only accepted source/export assets and sanitized evidence required by the Issue. Keep temporary renders, provider responses, caches, and rejected revisions outside Git. Never store credentials, private reference material, or unverifiable license claims in the asset or evidence.
