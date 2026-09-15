# System Experiences Plan

Status: [確定／提案／未決]

## Identity and release

- App: [display name / repository]
- Release identifier: [stable release ID]
- Revision: [positive revision]
- Product goal: [approved goal]
- Deployment Target: [confirmed app specification reference]
- Planning Issue: [Issue URL]
- Decision: [Decision anchor]
- User approval reference: [required before final confirmed state]

## Apple primary-source refresh

| Surface | checkedAt | source URL | availability | constraints | Effect on this plan |
| --- | --- | --- | --- | --- | --- |
| `widget` | [ISO 8601] | [developer.apple.com URL] | [observed platforms/contexts] | [time-varying constraints] | [effect] |
| `live-activities` | [ISO 8601] | [developer.apple.com URL] | [observed platforms/contexts] | [time-varying constraints] | [effect] |
| `dynamic-island` | [ISO 8601] | [developer.apple.com URL] | [observed devices/contexts] | [time-varying constraints] | [effect] |
| `controls` | [ISO 8601] | [developer.apple.com URL] | [observed platforms/contexts] | [time-varying constraints] | [effect] |
| `siri-app-intents` | [ISO 8601] | [developer.apple.com URL] | [observed integrations] | [time-varying constraints] | [effect] |

Use Apple official sources as the primary evidence. Recheck current pages at execution time; do not treat this record as permanent future-OS documentation.

## Required decision matrix

Allowed decisions are exactly `adopt-now`, `defer`, `not-applicable`, or `blocked:user`. Every row is required.

| Surface | Decision | Product reason | Current release impact | Current fallback / alternative | Reevaluation trigger | Dependent or follow-up Issues |
| --- | --- | --- | --- | --- | --- | --- |
| `widget` | [decision] | [reason] | [impact] | [fallback] | [trigger] | [Issues or None] |
| `live-activities` | [decision] | [reason] | [impact] | [fallback] | [trigger] | [Issues or None] |
| `dynamic-island` | [decision] | [reason] | [impact] | [fallback] | [trigger] | [Issues or None] |
| `controls` | [decision] | [reason] | [impact] | [fallback] | [trigger] | [Issues or None] |
| `siri-app-intents` | [decision] | [reason] | [impact] | [fallback] | [trigger] | [Issues or None] |

For `defer`, name the current release impact and reevaluation trigger. For `not-applicable`, give a product reason and alternative path. For `blocked:user`, name the exact question and only the dependent Issues that stop.

## Common record for every surface

Complete these fields for each of the five surface IDs. Use `Not applicable — <reason>` rather than leaving a field empty.

- 対象ユーザーtask: [task]
- 提供価値: [value]
- 対象OS／device／system space: [scope]
- 開始点: [entry]
- 成功結果: [result]
- データ所有者とsource of truth: [owner/source]
- 更新・同期・staleness: [model]
- offline／error／recovery: [behavior]
- privacy・lock-state redaction: [boundary]
- accessibility: [VoiceOver, Dynamic Type, reduced motion, input]
- 日英localization: [content and invocation coverage]
- fallback: [unsupported/unavailable path]
- telemetry privacy境界: [none, or purpose/minimum data/retention/consent]
- 検証方法: [unit/integration/native/device/review plan]
- release依存: [dependencies]
- 再評価条件: [specific trigger]

## Widget detail

- Glanceable value: [value]
- Placement and families: [Home Screen / Lock Screen / StandBy / supported families]
- Timeline, reload, and relevance: [plan]
- Configuration and interactivity: [plan]
- Deep link: [route]
- Empty, stale, and error states: [behavior]
- Shared data and App Group need: [minimum boundary]
- System-controlled update timing: [user-visible consequence]

## Live Activities detail

- Finite tracked event: [event and end condition]
- Start/update/end/dismiss/stale: [lifecycle]
- App-restart recovery: [plan]
- Local update or ActivityKit push: [choice and reason]
- APNs/server dependency: [dependency or None]
- Authorization: [behavior]
- Deep link and interactive action: [routes/actions]
- Lock Screen presentation: [information priority]

## Dynamic Island detail

- Relationship to Live Activity: [shared lifecycle]
- Minimal presentation: [priority]
- Compact presentation: [priority]
- Expanded presentation: [priority]
- Multiple activities: [behavior]
- Supported-device behavior: [behavior]
- Non-supporting device/context fallback: [fallback]

## Controls detail

- Button or toggle fit: [choice]
- System spaces: [Control Center / Lock Screen / Action button as currently available]
- Value provider and refresh: [plan]
- App Intent idempotency/concurrency/error: [contract]
- Foreground launch: [required/optional/never and reason]
- Device authentication/confirmation: [boundary]
- Locked-device redaction: [behavior]
- Configuration and deep link: [plan]

## Siri and App Intents detail

- Actions/entities/parameters/results: [contract]
- App Shortcuts: [shortcuts]
- Japanese invocation phrases: [phrases]
- English invocation phrases: [phrases]
- Siri/Shortcuts/Spotlight discoverability: [plan]
- Foreground/background execution: [boundary]
- Authentication/confirmation: [boundary]
- Cancellation/retry safety: [behavior]
- Voice-only/visual response: [responses]
- Unsupported/ambiguous input: [behavior]
- App Intents Testing: [verification]

## Cross-surface architecture

| Concern | App target | Shared domain/data | Widget extension | App Intent | External/server | Owner and ordering |
| --- | --- | --- | --- | --- | --- | --- |
| Business action | [responsibility] | [共有domain action] | [adapter only] | [reuse/separate] | [if any] | [owner] |
| Data/source of truth | [responsibility] | [owner] | [read/write boundary] | [access boundary] | [if any] | [owner] |
| Updates and recovery | [responsibility] | [state] | [timeline/activity/control] | [execution] | [APNs/server] | [ordering] |
| Privacy/authentication | [responsibility] | [policy] | [redaction] | [confirmation] | [policy] | [ordering] |
| Localization/accessibility | [responsibility] | [shared resources] | [target resources] | [phrases/dialog] | [Not applicable] | [ordering] |

- Extension process boundaries: [process and failure boundaries]
- Minimum App Group use: [needed data only or Not applicable]
- Data migration: [plan]
- Deep-link routing: [routes and ownership]
- Capability/entitlement/Info.plist/signing: [planned changes, not authorization]
- App Intent reuse decision: [reuse conditions and required separations]

## Issue graph and partial blocking

```text
System Experiences Planning Issue
  -> [shared foundation Issue when needed]
  -> [surface-specific shape/harden Issues]
  -> [release Issue]
```

- Serialized write-sets: [Xcode project / target / entitlement / App Group / signing / localization groups]
- UI Direction dependencies: [adopted system UI Issues]
- `blocked:user` dependent Issues: [only affected Issues]
- Independent non-UI Issues allowed to continue: [Issues]
- `defer` / `not-applicable` follow-up location: [spec or backlog]

## Decision history

- Previous record/Decision: [anchor or None]
- Supersedes: [anchor or None]
- Change reason: [reason]
- Affected release scope and Issues: [scope]
- Invalidated evidence: [evidence or None]
- Preserved evidence and reason: [evidence or None]
- Recorded by / authority: [actor and user approval reference]
