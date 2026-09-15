---
name: ios-system-experiences
description: Use when planning whether an iOS app should adopt Widget, Live Activities, Dynamic Island, Controls, and Siri/App Intents after Identity bootstrap and before major Feature Issue planning or Claim; do not use this skill to implement those surfaces.
---

# iOS System Experiences Planning

Evaluate every system experience, but adopt only what has product value and an acceptable implementation cost. This is a non-UI planning gate. It never authorizes Xcode target creation, entitlement changes, APNs setup, provider mutation, or native UI implementation.

## When the gate runs

Run one dedicated System Experiences Planning Issue after Identity bootstrap and before planning or claiming the app's 主要Feature Issue. The product adoption decision belongs to release Phase 1; adopted architecture is refined in Phase 2. If the planning result changes an already approved release scope, use `spec-workflow` and the release revision rules instead of silently changing Phase 1.

The planning Issue may run in parallel with the App Icon Issue. App Icon selection is not a system-experience decision. An adopted system UI Issue depends on this planning Issue and must separately pass `ui-direction`; independent non-UI work continues.

Existing generated apps are not enrolled retroactively. Run the gate for them only when the user explicitly requests reassessment or when a recorded reevaluation trigger applies.

## Refresh Apple primary sources

At every execution, retrieve current Apple公式 documentation from `developer.apple.com`. Do not rely only on the links or facts remembered from an earlier run, and do not use a blog or search summary as the primary source. Start with these official entry points and follow current linked pages when the plan needs more detail:

- Widget strategy: <https://developer.apple.com/documentation/WidgetKit/Developing-a-WidgetKit-strategy>
- Live Activities: <https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities>
- Controls: <https://developer.apple.com/documentation/widgetkit/creating-controls-to-perform-actions-across-the-system>
- App Intents: <https://developer.apple.com/documentation/appintents>

For every source used, record `checkedAt`, the exact source URL, observed platform `availability`, and relevant `constraints` in the planning record. Treat availability, supported system spaces, payload/update behavior, and API limits as time-varying observations. Confirm them again against the app's Deployment Target before an implementation Issue is approved. Do not permanently encode a future OS version or numeric service limit in this template.

## Create the planning record

Read and copy [`templates/system-experiences-plan.md`](templates/system-experiences-plan.md) into the app's confirmed specifications. Bind it to one release identifier and revision. Use synthetic examples only; do not include secrets, production data, APNs tokens, account identifiers, or personal telemetry.

Evaluate these stable surface IDs separately:

1. `widget`
2. `live-activities`
3. `dynamic-island`
4. `controls`
5. `siri-app-intents`

Choose exactly one decision for every surface:

- `adopt-now`: the current release has a concrete user task and value; create the required design and implementation Issues.
- `defer`: do not implement in the current release; record its release impact, current fallback, follow-up location, and a concrete reevaluation trigger.
- `not-applicable`: record the product reason and current alternative path. Technology unavailability alone is not a product reason.
- `blocked:user`: record the exact decision needed and only the dependent Issues that stop. This is 部分blocking; unrelated planning and independent non-UI work continue.

An empty row, `TBD`, implicit non-support, or a decision without its required reason is invalid. Make a recommendation, but the ユーザーのfinal approval governs the app-specific matrix. Record the approval reference and approved release revision through `spec-workflow`; silence is not approval.

## Evaluate product value before technical reuse

For every surface, first record the target user task, expected value, entry point, successful result, target OS/device/system space, and fallback. Then complete the common data, failure, privacy, accessibility, localization, verification, release-dependency, and reevaluation fields in the template.

Shared frameworks do not imply shared product value. In particular, do not adopt a Widget only because a Live Activity uses a widget extension, and do not expose an App Intent only because Controls can reuse one.

### Widget

Plan the glanceable value, placement/families, configuration, timeline/reload/relevance behavior, interactivity, deep link, empty/stale/error state, data sharing and App Group need, lock-state privacy, and the fact that the system controls update opportunities.

### Live Activities

Confirm that the task is a finite event worth tracking. Plan start, update, end, dismiss, stale behavior, recovery after app restart, local versus ActivityKit push updates, APNs/server dependency, authorization, deep link, interaction, and Lock Screen presentation.

### Dynamic Island

Treat this as a presentation of the same Live Activity, not as a normal Widget or a separate lifecycle. Plan minimal, compact, and expanded information priority, multiple-activity behavior, supported-device presentation, and the fallback on devices or contexts without Dynamic Island.

### Controls

Plan whether a button or toggle fits, the system spaces where it may appear, value provider and refresh, App Intent idempotency/concurrency/error behavior, foreground launch, authentication/confirmation, locked-device redaction, configuration, and deep link.

### Siri and App Intents

Plan actions, entities, parameters, results, App Shortcuts and Japanese/English invocation phrases, Siri/Shortcuts/Spotlight discoverability, foreground/background execution, authentication/confirmation, cancellation and retry safety, voice-only and visual responses, ambiguous/unsupported input, and App Intents Testing.

## Design adopted surfaces together

For each `adopt-now` decision, create an architecture dependency table before feature implementation:

- Put reusable business behavior in a 共有domain action rather than duplicating it in an extension or intent.
- Decide when one App Intent can safely serve Widget, Live Activity, Control, and Siri, and when authentication, parameters, results, or side effects require separate intents.
- Record app and extension process boundaries, the single data owner/source of truth, the minimum App Group use, migration, deep-link routing, offline/stale/error recovery, lock-state privacy, capability/entitlement/Info.plist/signing changes, and target localization.
- Distinguish timeline, ActivityKit update, Control refresh, and App Intent execution models. Never present one as the other.
- Record whether foreground execution, device authentication, user confirmation, network, APNs, or a server is required. These observations do not authorize external setup.

## Produce implementation-ready Issues

Use `plan-issue-batch` to produce only the Issues implied by `adopt-now` decisions:

```text
System Experiences Planning Issue
  -> shared domain/App Intent/data foundation Issue when needed
  -> surface-specific shape or harden Issue
  -> release Issue
```

Serialize overlapping Xcode project, target, entitlement, App Group, signing, and localization write-sets. Keep independently verifiable surfaces separate. A surface UI Issue applies `ui-direction` and native iOS verification; the planning artifact is not Build, Simulator, visual, or accessibility evidence.

Create no implementation Issue for `defer` or `not-applicable`. Preserve the reevaluation trigger in the app specification or backlog. A `blocked:user` result stops only named dependent Issues.

## Reevaluate

Reopen this decision when the app's Deployment Target, release goal, primary flow, data ownership, account/push/privacy requirements, or relevant Apple official guidance materially changes. Append a new Decision that supersedes the earlier one; do not overwrite the previous planning record or sealed Issue contracts.
