---
name: save-appstore-metadata
description: Save only confirmed, selected App Store localization text through the guarded asc adapter, with baseline, readback and a separate sanitized journal.
---

# Save App Store Metadata

Use this skill for `submit-appstore-release` `save` mode only. Read [the selective-save contract](../../../docs/agent-contracts/appstore-submission.md#operation-modes-and-selective-metadata-save), `docs/AUTHORITY.md`, the owning Issue and the current preparation report first. The app's Issue must declare `appstore.update_metadata` for the current executor. A fresh `provider-preflights/app-store-update_metadata.json` for the same Issue, Team and Bundle is required. This skill never creates an App/version, changes release settings, uploads images or a build, or submits a review.

The public entrypoint is:

```sh
.agents/skills/save-appstore-metadata/scripts/save-appstore-metadata.sh \
  --project-root "$APP_ROOT" \
  --request .artifacts/appstore-metadata/requests/<request-id>.json
```

Use `--resume-attempt <attempt-id>` with the **same request bytes** to start a new attempt that references an earlier attempt. Read the returned status and the per-form append-only events under `.artifacts/appstore-metadata/<issue>/<attempt>/`. `remote-saved` requires complete readback of selected and preserved fields. `unknown`, `blocked`, `stale` and `partial` are not release evidence. The script never writes `App Store/submission/`.

The UTF-8 request has `recordType: appstore-metadata-save-request`, `schemaVersion: 1`, `issue`, `executor`, `identity` (`teamId`, `bundleId`, `appId`, `platform: IOS`, `version`), `sourceRevision`, `requirements` (`checkedAt` and the three Apple reference URLs in the contract), `publicationImpactApprovalReference` (null unless explicitly authorized), `forms`, and `selectedFields`. Each form identifies `section`, `locale`, the exact `asc://apps/<appId>/<resource>/<resourceId>` reference, and a `baselineDigest` of the complete normalized form. Each selected field has `fieldId`, `locale`, and `source` (`path`, `anchor`, `digest`). The request contains no field value. Obtain the baseline from an authorized, reviewed remote read; an unobserved or mismatching digest blocks the form. Only `name`, `subtitle`, `description`, `keywords`, `promotionalText` and `whatsNew` are selectable. `whatsNew` maps to the preparation `releaseNotes` row. Values come from confirmed `App Store/` sources at invocation time.

The normalized form for `baselineDigest` has exact keys `section`, `locale`, `remoteReference`, `values`. `values` contains every modeled attribute for that resource, preserving `null` and empty strings; the writer rejects a missing or extra attribute. Recursively sort JSON object keys, emit compact UTF-8 JSON without a trailing newline, hash those exact bytes with SHA-256, and prefix the lowercase digest with `sha256:`. The journal binds the exact request **bytes** separately. Do not put raw form values in the request, journal, Issue or review evidence.

`promotionalText` is treated as an immediate public-page change and requires an explicit `approval: user-approval://...` reference scoped by the owning Issue. The other five fields require an editable selected version and are treated as next-version changes. Unknown effects/statuses stop. The tool uses only the pinned `asc` runner. Its local fake-runner override works only with `IOS_TEMPLATE_TEST_MODE=1`; production mode rejects it.

The user separately authorizes full `ready`/`submit` gates. A partial save journal cannot replace a sealed package or an ordered release result.
