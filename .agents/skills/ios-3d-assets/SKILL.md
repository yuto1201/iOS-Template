---
name: ios-3d-assets
description: Choose the iOS 3D authoring route by model complexity (D-082) — Claude in Blender for very simple shapes, the Codex loop (gpt-6.1-sol reference images and gpt-6-astra models, both xhigh) for simple models and simple part motion, and Tripo in the browser for complex or skeleton-rigged models — then integrate and verify the accepted asset against the app budgets.
---

# iOS 3D Assets

Use this skill when an approved Issue requires creating, generating, or structurally revising a 3D model, mesh, material, rig, or animation. Do not invoke it merely because existing 3D bytes are being copied, integrated, or deterministically validated.

## Authoring routes (D-082)

Choose one route per asset revision and record it in the Issue/PR evidence as `claude`, `codex`, or `tripo`. D-082 supersedes the D-071 rule that made Tripo the default for every model.

| Route | Use it for | Who authors |
| --- | --- | --- |
| `claude` | A very simple shape: a few boxes, cylinders, or spheres with flat colors | Claude, in Blender |
| `codex` | A simple model: hard-surface or low-poly, a handful of parts, simple or stylized textures; and simple part motion (rotate, open, slide, extend) | Codex `gpt-6.1-sol` (reference images) and `gpt-6-astra` (model), both with reasoning effort `xhigh`; Claude evaluates |
| `tripo` | A complex model that needs Tripo's quality: organic forms (people, animals, cloth, food), many parts, photorealistic textures; and any model that moves with a skeleton | The user or Claude, operating Tripo in the browser |

### Choosing the route

Before authoring, judge the model on four criteria and write the result and the reason in the Issue:

1. Shape: combinations of boxes, cylinders, and spheres, or organic forms.
2. Number of parts.
3. Texture: flat colors or simple patterns, or photorealistic detail.
4. Motion: none, simple part motion, or a skeleton (rig).

When the criteria point to one route, proceed. When they do not clearly decide between two routes, ask the user and keep the Issue `blocked:user` until they choose. The user may always override the route.

### A set of models: style reference first

When an Issue creates several models that appear together, first have Codex `gpt-6.1-sol` (`xhigh`) generate two style reference images for the whole set (palette, shading, proportions, level of detail). The user chooses one; keep the Issue `blocked:user` until they do. Every model's reference image then follows the chosen style, and every model uses the same scale convention. A single model needs no style reference.

## Claude route

Claude builds the shape with Blender Python (`bpy`), exports GLB and USDZ, and evaluates the renders described in the Codex route. Use it only for very simple shapes; when the model needs more than that, switch to the Codex route.

## Codex route

1. **Reference image.** Ask Codex `gpt-6.1-sol` with reasoning effort `xhigh` to generate the reference image of the wanted asset (and, for a set, in the chosen style). Claude evaluates it against the Issue's requirements and asks for corrections. At most 5 rounds.
2. **Model.** Give the accepted image to Codex `gpt-6-astra` with reasoning effort `xhigh`. It builds the model with Blender Python (`bpy`), keeps the `.blend` source, and exports GLB and USDZ.
3. **Evaluation.** Claude renders the model from the front, side, top, and a three-quarter view, including the angle of the reference image, and compares the renders with the reference, the scale, the origin, and the facing direction. Claude asks `gpt-6-astra` for corrections. At most 5 rounds.
4. **Limit.** When either loop reaches 5 rounds without an accepted result, stop and show the user the current result. The user decides whether to continue or switch to Tripo.
5. **Exact models.** A Codex handoff names `gpt-6.1-sol` or `gpt-6-astra` and `xhigh` explicitly, and the evidence records the actual model. When either model is unavailable, stop as `blocked:environment`; never substitute another model.

Simple part motion (rotate, open, slide, extend) is authored in the same route as a Blender animation and exported with the model.

## Tripo route

The user signs in, changes the plan or billing, and enters any credentials. Claude never types a password, payment detail, or token, never buys credits, never changes account settings, and never accepts terms on the user's behalf. Claude works only inside the user's already signed-in session.

Before every operation that spends credits — image generation, model generation, a paid fix, texture generation, rigging — show the user the expected credit cost and wait for approval. The free partial fixes need no confirmation. Ask the user before each download.

Procedure (UI checked 2026-10-14):

1. Always build the model from a generated image. Never generate a model from text alone; the result rarely matches the wanted asset.
2. Use multi-view generation for the image, and evaluate every view before modeling.
3. Set the topology and the polygon count first, then set the number of generations to 4 (it costs the same credits as 1). Pick the best result.
4. When the chosen model is incomplete, use the partial fix at the bottom of the screen first (the first 3 fixes spend no credits).
5. Then generate the texture, and send fine corrections to Codex `gpt-6-astra` (`xhigh`) in Blender.
6. For a model that moves with a skeleton, use Tripo's rigging, then verify the animation as below.

When the Tripo screen differs from this procedure (renamed, moved, or missing controls), stop before any credit-spending operation and report the difference to the user. Do not guess an equivalent control.

Before committing a Tripo output to an app that will ship, confirm with the user that their Tripo plan permits that commercial use.

## App budgets and verification

Per model, unless the Issue records a reason and the user approves a larger budget:

| Kind | Triangles | Texture | USDZ size |
| --- | --- | --- | --- |
| Small prop | 5,000 or fewer | 1024 px | 2 MB or less |
| Hero model | 30,000 or fewer | 2048 px | 10 MB or less |

Whatever the route, the owning Issue validates every required source and export independently: GLB validation, USDZ validation, RealityKit loading, animation playback, and the appearance in both Light and Dark appearance. Treat GLB validation, USDZ validation, ARKit compatibility checks, RealityKit loading, animation playback, and physical-device behavior as separate claims; do not infer one from another.

## Evidence and boundary

Before authoring, specify the intended object, scale and coordinate conventions, topology and polygon budget, materials and textures, rig/animation requirements, target formats, visual references and rights, and acceptance views. Unresolved choices that change the expected asset are `blocked:user`.

Record the route (`claude`, `codex`, or `tripo`), the models used, the number of rounds, the generation date, the prompts or reference descriptions, the accepted reference images, and the export formats. For Tripo, record the credits the user approved. Do not record account identifiers, session data, or billing details.

Claude and Codex retain equal authority for general development. Either may prepare confirmed requirements and references, integrate an accepted asset, implement RealityKit behavior, run Blender or platform validators, Build/Test the app, inspect rendered output, or review the result.

Stay inside the Issue scope and preserve source files needed for reproducibility. Commit only accepted source/export assets and sanitized evidence required by the Issue. Keep temporary renders, rejected references, provider responses, caches, and rejected revisions outside Git. Never store credentials, private reference material, or unverifiable license claims in the asset or evidence.
