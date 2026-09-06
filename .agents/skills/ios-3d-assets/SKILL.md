---
name: ios-3d-assets
description: Route iOS 3D model, mesh, material, rig, or animation authoring exclusively to Codex using the exact gpt-6-astra model while allowing Claude or Codex to integrate and verify accepted assets.
---

# iOS 3D Assets

Use this skill when an approved Issue requires creating, generating, or structurally revising a 3D model, mesh, material, rig, or animation. Do not invoke it merely because existing 3D bytes are being copied, integrated, or deterministically validated.

## Fixed authoring route

- The author of new or structurally changed 3D asset bytes must be Codex running the exact model identifier `gpt-6-astra`.
- If the current worker is Claude or another Codex model, keep the Issue ownership if appropriate but hand off only the 3D authoring subtask to a Codex task or sub-agent configured with exact `gpt-6-astra`.
- If that exact model cannot be selected or its identity cannot be verified, stop the authoring work as `blocked:environment`. Do not substitute Claude, another Codex model, or an unverified provider result.
- Record `gpt-6-astra` as the authoring model in the Issue/PR evidence for every accepted 3D revision. A label alone is not proof when the execution environment exposes stronger model identity evidence.

Claude and Codex retain equal authority for general development. Either may prepare confirmed requirements and references, integrate an accepted asset, implement RealityKit behavior, run Blender or platform validators, Build/Test the app, inspect rendered output, or review the result. These activities do not permit a non-Astra worker to create or reshape the 3D asset bytes.

## Authoring boundary

Before handoff, specify the intended object, scale and coordinate conventions, topology or polygon budget, materials and textures, rig/animation requirements, target formats, visual references and rights, and acceptance views. Unresolved choices that change the expected asset are `blocked:user`.

The Astra authoring task may select the appropriate local tools, including Blender and format converters, but must stay inside the Issue scope and preserve source files needed for reproducibility. After authoring, the owning Issue validates every required source and export independently. For Apple integration, treat GLB validation, USDZ validation, ARKit compatibility checks, RealityKit loading, animation playback, and physical-device behavior as separate claims; do not infer one from another.

Commit only accepted source/export assets and sanitized evidence required by the Issue. Keep temporary renders, provider responses, caches, and rejected revisions outside Git. Never store credentials, private reference material, or unverifiable license claims in the asset or evidence.
