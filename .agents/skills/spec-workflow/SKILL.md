---
name: spec-workflow
description: Use when drafting or changing iOS-Template specifications, deciding whether an Issue is implementation-ready, or checking references to 確定, 提案, and 未決 decisions.
---

# Specification Workflow

Keep `specs/` as the product truth and preserve the append-only decision history.

## Required workflow

1. Read `specs/README.md`, the Issue-referenced specifications, then `specs/decisions.md` and, in a derived app, `specs/app-decisions.md`.
2. Classify each relevant choice as `確定`, `提案`, `未決`, or `廃止` using `specs/README.md`.
3. If `提案` or `未決` changes an acceptance criterion, do not implement. Mark the Issue `blocked:user` and obtain the user's decision.
4. Record a changed decision by appending a new entry. In the template, append `D-###` to `specs/decisions.md`; in a derived app, append `A-###` to `specs/app-decisions.md` and never add a decision to `specs/decisions.md`. State which earlier decision it supersedes; never rewrite history.
5. Update the affected specification and Issue acceptance criteria before implementation resumes.
6. Save the current Issue body locally and run:

```sh
.agents/skills/spec-workflow/scripts/check-spec-state.sh issue-body.md
```

Start implementation only when the checker exits `0` and the Issue contract matches the approved acceptance criteria.

## Decision entries

Copy [`templates/decision.md`](templates/decision.md) when a decision must be appended. Use the next ID in the right log and remove fields that genuinely do not apply.

- Template decisions are `D-###` in `specs/decisions.md`. A `D-###` reference in template-owned documents and tools (`AGENTS.md`, `docs/`, existing `specs/` sections, `.agents/skills/`, `tools/`) always means a template decision, including inside a derived app.
- A derived app records its own decisions as `A-###`, starting at `A-001`, in `specs/app-decisions.md`. Create that file with its first app decision.
- When a derived app takes a template update, append the template's new `D-###` entries to the end of `specs/decisions.md` in their original order and numbers. Leave `specs/app-decisions.md` unchanged.
- The checker reads a linked decision's own `- Status:` line, and rejects a `D-###` link into `specs/app-decisions.md` or an `A-###` link into `specs/decisions.md`. See D-069.

| State | Implementation meaning |
| --- | --- |
| `確定` | May be implemented. Changes require a superseding Decision. |
| `提案` | May be discussed; cannot drive acceptance-affecting implementation. |
| `未決` | Requires the user; set `blocked:user`. |
| `廃止` | Must not be treated as current specification. |

## Common mistakes

- Treating a reasonable default as approval when acceptance criteria change.
- Editing an earlier Decision instead of appending a superseding entry.
- Checking the Issue text without following its local Markdown links and anchors.
- Resuming implementation before both the specification and Issue are updated.
