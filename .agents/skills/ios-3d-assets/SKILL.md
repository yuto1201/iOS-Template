---
name: ios-3d-assets
description: Choose the iOS 3D authoring route by model complexity (D-082) — Claude in Blender for very simple shapes, the Codex loop (gpt-6.1-sol reference images and gpt-6-astra models, both xhigh) for simple models and simple part motion, and Tripo in the browser for complex or skeleton-rigged models — then integrate and verify the accepted asset against the app budgets. This repository adapter defers the authoring procedures to the shared Mac skill 3d-asset-design.
---

# iOS 3D Assets

Use this skill when an approved Issue requires creating, generating, or structurally revising a 3D model, mesh, material, rig, or animation. Do not invoke it merely because existing 3D bytes are being copied, integrated, or deterministically validated.

## Shared authoring skill

This skill is the repository adapter. The authoring procedures (the Claude route in Blender, the Codex reference-image and model loops, the style reference for a set, and the Tripo screen procedure) live in the shared Mac skill `3d-asset-design` at `~/.agents/skills/3d-asset-design/`, which Claude and Codex both read. In this repository, D-082 and `AGENTS.md` take precedence over the shared skill, and this adapter's budgets, verification, and evidence rules apply to every route.

When the shared skill cannot be read in the current environment, stop as `blocked:environment` before authoring. Do not reconstruct its procedures from memory or substitute another route.

## Authoring routes (D-082)

Choose one route per asset revision and record it in the Issue/PR evidence as `claude`, `codex`, or `tripo`.

| Route | Use it for | Who authors |
| --- | --- | --- |
| `claude` | A very simple shape: a few boxes, cylinders, or spheres with flat colors | Claude, in Blender |
| `codex` | A simple model, and simple part motion (rotate, open, slide, extend) | Codex `gpt-6.1-sol` (reference images) and `gpt-6-astra` (model); Claude evaluates |
| `tripo` | A complex model that needs Tripo's quality, and any model that moves with a skeleton | The user or Claude, operating Tripo in the browser |

### Choosing the route

Before authoring, judge the model on four criteria and write the result and the reason in the Issue: Shape, Number of parts, Texture, and Motion. When the criteria do not clearly decide between two routes, ask the user and keep the Issue `blocked:user` until they choose. The user may always override the route.

### Codex models and limits

A Codex handoff names Codex `gpt-6.1-sol` with reasoning effort `xhigh` for reference images and Codex `gpt-6-astra` with reasoning effort `xhigh` for the model, and the evidence records the actual model. When either model is unavailable, stop as `blocked:environment`; never substitute another model. Each evaluation loop allows At most 5 rounds; then stop and show the user the current result, and the user decides whether to continue or switch to Tripo.

## Tripo safety

The user signs in, changes the plan or billing, and enters any credentials. Claude never types a password, payment detail, or token, never buys credits, never changes account settings, and never accepts terms on the user's behalf. Claude works only inside the user's already signed-in session.

Before every operation that spends credits, show the user the expected credit cost and wait for approval. Ask the user before each download. When the Tripo screen differs from the shared skill's procedure, stop before any credit-spending operation and report the difference to the user. Before committing a Tripo output to an app that will ship, confirm with the user that their Tripo plan permits that commercial use.

## App budgets and verification

Per model, unless the Issue records a reason and the user approves a larger budget:

| Kind | Triangles | Texture | USDZ size |
| --- | --- | --- | --- |
| Small prop | 5,000 or fewer | 1024 px | 2 MB or less |
| Hero model | 30,000 or fewer | 2048 px | 10 MB or less |

Whatever the route, the owning Issue validates every required source and export independently: GLB validation, USDZ validation, RealityKit loading, animation playback, and the appearance in both Light and Dark appearance. Treat GLB validation, USDZ validation, ARKit compatibility checks, RealityKit loading, animation playback, and physical-device behavior as separate claims; do not infer one from another.

## Evidence and boundary

Before authoring, specify the intended object, scale and coordinate conventions, topology and polygon budget, materials and textures, rig/animation requirements, target formats, visual references and rights, and acceptance views. Unresolved choices that change the expected asset are `blocked:user`.

Record the route, the models used, the number of rounds, the generation date, the prompts or reference descriptions, the accepted reference images, and the export formats. For Tripo, record the credits the user approved. Do not record account identifiers, session data, or billing details.

Claude and Codex retain equal authority for general development. Stay inside the Issue scope and preserve source files needed for reproducibility. Commit only accepted source/export assets and sanitized evidence required by the Issue. Keep temporary renders, rejected references, provider responses, caches, and rejected revisions outside Git. Never store credentials, private reference material, or unverifiable license claims in the asset or evidence.
