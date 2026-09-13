# Opposite-model review contract

## 1. 目的

`strict`または`release` Issueでは、主開発モデルとは異なるモデルが現在のHead SHAに対して受け入れ条件、実装、検証証拠をread-onlyで評価します。`standard`の`shape`／`harden`とexplicit `fast`はblocking reviewを要求せず、review packetを作成しません。stage未導入のClaim済みIssueは旧release-level reviewを維持します。

## 2. Review packet

`tools/prepare-review-packet.sh` は、信頼済みBaseと現在のHeadから決定論的なactual Git diffを生成し、canonical verify.jsonとそのvisual evidenceをdescriptor-boundで読み、一つのschema v2 packetへ封印します。`repository-tests.json` が同じIssue/Headに存在する場合は、runner bytes、実行時刻、AC別対応を検証し、`repositoryTests` としてpacket内へ値ごと封印します。D-037 plan-required contractではcanonical `repository-test-plan.json`をimmutable Git入力から再計算し、その値／path／digestとschema v3 repository evidenceを同時に封印します。Acceptance criteriaとspec anchorsはIssue contractから読み、すべてexact bytesのdigestで固定します。liveな`UI verification`本文はIssue contractにもreview packetにも含めません。

UI-direction compatibility is determined only from the sealed Issue contract. A declaration candidate is any existing acceptance-criterion text that begins with the exact `UI-direction route:` prefix, immediately after its `AC-*:` ID. It is valid only in the exact form `UI-direction route: <route>; Scope: <nonempty>; Reason: <nonempty>`, where `<route>` is exactly `comparison`, `explicit-skip`, `confirmed-direction reuse`, `bounded direction-neutral`, or `not-applicable`; route-specific facts may follow Reason. Incidental route words outside that prefix, including prose that lists every route, do not create a candidate. Compare `fetchedAt` as a UTC instant with `2026-09-06T00:31:41Z`: an earlier contract is pre-D-030 legacy only when it has zero candidates, so the packet/reviewer must not infer a route, demand retroactive HTML or a route declaration, or modify/reseal that contract; review its original sealed AC, spec anchors, Dependencies, and current-Head evidence. If an earlier contract has one or more candidates, validate it normally and reject unless exactly one candidate is fully valid; malformed, unknown-route, empty Scope/Reason, and multiple-candidate cases are not legacy. A contract at or after the cutoff has the same exactly-one and validity requirements, including rejection when no candidate exists. The packet preserves the Issue-contract path and digest needed for that classification and never substitutes Issue number, update time, file mtime, or live UI verification. For non-legacy contracts, formal reviewers identify the route only from the valid AC-text declaration and validate its Scope, Reason, and route-specific facts using the packet-bound Issue contract's Goal, Acceptance criteria, Spec anchors, Dependencies, linked confirmed spec/Decision, current-Head diff, and evidence. schema v1は通常レビューの既存成果物を読む場合に限る互換形式で、pre-merge gateは受理しません。

Opposite-review routing is also derived only from the sealed Acceptance criteria. With no declaration, the compatible defaults remain Codex primary→`claude` and Claude primary→`codex`. The only exception is exactly one criterion whose text begins with exact `Opposite-review route: grok-fallback; Primary: codex; Reviewer: cursor-grok-4.6-xhigh; Approval: user-explicit; Reason: <nonempty>`. It selects `cursor-grok-4.6-xhigh` only for a Codex primary. Duplicate, malformed, incomplete, different-primary/model/approval declarations are rejected; an incidental mention does not select Grok. There is no runtime flag, silent fallback, Claude-primary Grok route, or self-approval. Existing sealed contracts without the declaration retain their default pair and bytes.

```json
{
  "schemaVersion": 2,
  "issue": 42,
  "primaryModel": "codex",
  "reviewerModel": "claude",
  "baseSha": "fedcba9876543210fedcba9876543210fedcba98",
  "headSha": "0123456789abcdef0123456789abcdef01234567",
  "verifySha": "0123456789abcdef0123456789abcdef01234567",
  "issueContract": {
    "path": ".artifacts/issues/42/issue-contract.json",
    "digest": "sha256:83346f064f2e8c2df561bc36b3440384621145b2189a5c6dc38966a100da2f6e"
  },
  "specAnchors": ["specs/features/settings.md#notification-time"],
  "acceptanceCriteria": [
    {"id": "AC-1", "text": "UI-direction route: confirmed-direction reuse; Scope: 通知時刻設定行; Reason: リンク済み仕様が同じhierarchyとflowを確定済み。 Covered hierarchy/flow: settings list > notification-time row > time picker."},
    {"id": "AC-2", "text": "通知時刻を保存して日本語で正しく表示できる"}
  ],
  "diff": {
    "path": ".artifacts/issues/42/0123456789abcdef0123456789abcdef01234567/review.diff",
    "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  },
  "verify": {
    "path": ".artifacts/issues/42/0123456789abcdef0123456789abcdef01234567/verify.json",
    "digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  },
  "repositoryTests": {
    "schemaVersion": 1,
    "status": "passed",
    "issue": 42,
    "baseSha": "fedcba9876543210fedcba9876543210fedcba98",
    "headSha": "0123456789abcdef0123456789abcdef01234567",
    "issueContract": {"path": ".artifacts/issues/42/issue-contract.json", "digest": "sha256:83346f064f2e8c2df561bc36b3440384621145b2189a5c6dc38966a100da2f6e"},
    "runnerFiles": [
      {"path": "tools/run-repository-tests.sh", "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
      {"path": "tools/lib/run-repository-tests.rb", "digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
    ],
    "suite": {"path": "tools/tests", "pattern": "test-*.sh", "total": 2, "passed": 2, "failed": 0},
    "tests": [
      {"path": "tools/tests/test-provider-ownership.sh", "arguments": [], "status": "passed", "exitStatus": 0, "outputDigest": "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", "startedAt": "2026-08-21T13:00:00Z", "completedAt": "2026-08-21T13:01:00Z"},
      {"path": "tools/tests/test-workflow-state.sh", "arguments": [], "status": "passed", "exitStatus": 0, "outputDigest": "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd", "startedAt": "2026-08-21T13:01:00Z", "completedAt": "2026-08-21T13:02:00Z"}
    ],
    "acceptanceEvidence": [
      {"id": "AC-1", "status": "passed", "tests": ["tools/tests/test-provider-ownership.sh"]},
      {"id": "AC-2", "status": "passed", "tests": ["tools/tests/test-workflow-state.sh"]}
    ],
    "startedAt": "2026-08-21T13:00:00Z",
    "completedAt": "2026-08-21T13:02:00Z"
  },
  "imageFiles": [
    {"path": ".artifacts/issues/42/0123456789abcdef0123456789abcdef01234567/iphone-en/settings.png", "digest": "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"},
    {"path": ".artifacts/issues/42/0123456789abcdef0123456789abcdef01234567/iphone-ja/settings.png", "digest": "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"},
    {"path": ".artifacts/issues/42/0123456789abcdef0123456789abcdef01234567/ipad-en/settings.png", "digest": "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"},
    {"path": ".artifacts/issues/42/0123456789abcdef0123456789abcdef01234567/ipad-ja/settings.png", "digest": "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"}
  ]
}
```

例のパスと値は旧schema v1形式を示します。実際のIssue、仕様、SHA、画像を使用します。`repositoryTests` は同じHeadのcanonical `repository-tests.json` がある場合だけ存在します。plan-required packetは追加で`repositoryTestsFile`、`repositoryTestPlan`、`repositoryTestPlanFile`を持ち、reviewerはrequested／resolved scope、changed paths、exact test list、AC別mappingを確認します。

## 3. Reviewer questions

### BaseとHeadを要求するcontract

sealed AC本文先頭にcutover前のexact `Repository-test scope: base-and-head; <nonempty>`またはcutover後のexact `Repository-test scope: base-and-head; Reason: <nonempty>`が一つある場合、[両revision repository record](../verification.md#baseとheadの全repository-tests)を必須にする。packet schemaは2を維持する。cutover前はschema v2 recordと`repositoryTestsFile`、cutover後はschema v3 recordに加えて`repositoryTestPlan`／`repositoryTestPlanFile`を持つ。欠落field、canonical bytesと埋め込み値の相違を受理しない。

reviewerはordered `revisions`のBase／Head各SHAと全inventory、producerの現在Head、実行結果・時刻・timeout、AC mappingを確認する。Baseはbaseline／regressionの根拠であり、Headの新機能を実装済みと証明しない。新形式の各`supported` ACには、同じACのzero-based indexを使ったexact `repository-tests.json#acceptanceEvidence/INDEX`を含める。たとえばAC-1は`repository-tests.json#acceptanceEvidence/0`であり、別ACのmapping、存在しないpointer、prose、Headだけの参照で置き換えない。必要なiOS証拠は追加引用する。

このrouteでは`strict_references!`も`repositoryTestsFile`を返す。descriptor-owning callerはそのrecordを保持し、pure `validate!`へ`repository_tests_bytes:`と、信頼済みBase／Headから独立取得した`revision_context:`を渡す。contextは`ReviewContract.repository_revision_context(repo:, base_sha:, head_sha:)`で取得し、artifactのtested SHAや自己申告inventoryから組み立てない。packet-only preflight、結果検証、result／receipt publication、最終mergeの各ownerがrecordのdescriptor・path identity・bytesを確認する。receipt schemaは変更せず、recordを含むexact packet digestへ従来どおり束縛する。

### Plan-required contract

cutover後のworkflow-only contractは`targeted`、`head-all`、`base-and-head`の要求scopeとReasonをsealed ACに持つ。reviewerは`repositoryTestPlan`が示すmanifest／diff digest、changed paths、resolved scope、exact test paths、ordered AC mappingsとschema v3 `repositoryTests`の実行集合が一致することを確認する。descriptor-owning callerは`strict_references!`が返す`repositoryTestsFile`と`repositoryTestPlanFile`の両方を保持し、planをimmutable Base／Head／contract／Head manifestから再計算したうえで`validate!`へ`repository_tests_bytes:`、`repository_test_plan_bytes:`、`revision_context:`を渡す。D-039以後の`targeted`は既知の単一または複数domainに属するtestのunionを維持し、manifest、runner、tracked test変更から自動`head-all`へ昇格しない。未知pathはplan生成を拒否し、`head-all`／`base-and-head`はsealed contractの明示要求だけを認める。縮小や手書きのtest選択は認めない。

レビューでは次の順に確認します。

1. 各受け入れ条件に実装と証拠があるか。
2. 仕様外の振る舞いを追加・変更していないか。
3. correctness、state、concurrency、persistence、securityの問題がないか。
4. Issueの開発段階と宣言された範囲でUIに問題がないか。仕上げ・リリースではiPhone、iPad、日本語、英語の全範囲を確認する。
5. Testが重要な失敗経路を検出できるか。
6. Verify結果に未検証の事実主張がないか。
7. 現在のHead SHAを承認してよいか。

スタイル上の好みだけをBlocking findingにしません。

[段階的開発仕様](../../specs/development-stages.md)に従い、review-required Issueの宣言scopeだけを確認します。strict shapeは`iphone-ja`、strict hardenは`targeted`、releaseは`full`です。shape／hardenをrelease readyと解釈せず、packetはsealed contractへdigestで束縛します。

## 4. Result schema

```json
{
  "schemaVersion": 2,
  "issue": 42,
  "reviewerModel": "claude",
  "baseSha": "fedcba9876543210fedcba9876543210fedcba98",
  "headSha": "0123456789abcdef0123456789abcdef01234567",
  "verifySha": "0123456789abcdef0123456789abcdef01234567",
  "issueContractDigest": "sha256:83346f064f2e8c2df561bc36b3440384621145b2189a5c6dc38966a100da2f6e",
  "reviewPacketDigest": "sha256:9999999999999999999999999999999999999999999999999999999999999999",
  "verdict": "approved",
  "findings": [],
  "acceptanceAssessment": [
    {"id": "AC-1", "status": "supported", "evidence": ["verify.json#acceptanceEvidence/0"]},
    {"id": "AC-2", "status": "supported", "evidence": ["verify.json#cases"]}
  ],
  "reviewedAt": "2026-08-21T13:15:00+09:00"
}
```

`verdict` は `approved` または `changes-requested` のどちらかです。

Findingは次を含みます。

```json
{
  "severity": "high",
  "category": "correctness",
  "file": "TemplateApp/Settings/NotificationSettings.swift",
  "line": 38,
  "title": "保存値が再起動後に復元されない",
  "evidence": "load() が初期値だけを返し、保存先を読んでいない",
  "requiredChange": "保存先から値を復元する実装と再起動テストを追加する"
}
```

### Finding file resolution

`findings[].file` is a file path, not an evidence pointer or prose. Source paths
are relative to the executing Issue worktree root (or repository root in a
direct checkout), never the primary checkout's source tree or the caller's cwd.
Use the source-relative `file` example above.

Current packet artifacts may use the exact
`.artifacts/issues/ISSUE/HEAD/<path>` form. The packet's exact Issue contract path
is also allowed. Only the validated canonical `.artifacts` link is mapped to the
primary physical store; no other symlink is followed. Absolute paths, traversal,
other Issues/Heads, nested symlinks, leaf symlinks and hardlinks are rejected.

The unprefixed names `verify.json`, `review.diff`, `review-packet.json`,
`repository-tests.json`, `repository-test-plan.json` (when included in the packet), and the packet's image
paths are relative to the current packet's Issue/Head directory. These explicit
artifact aliases take precedence over same-named source files. All other paths
are source-relative; a missing source does not trigger a search in another root.
For other current-Head artifacts use the fully qualified `.artifacts/...` form.
Path resolution never rewrites the reviewer's finding or judgment.

### Rejected result recovery

If a parsed reviewer result fails validation, the fixed cross-model launcher
retains its complete JSON value (including verdict and findings) in a unique
`review-rejected-<uuid>.json` in the current Issue/Head directory. This diagnostic
has `status: rejected`, the launcher's Issue/Head, packet digest, rejection
classification and unmodified `result`. It is **not** `review.json`, an execution
receipt, approval evidence or a merge authorization. Raw provider envelopes and
authentication/session telemetry are not copied into it. The diagnostic uses
single-link, no-follow, exclusive 0600 publication and does not overwrite an
earlier attempt. If retention fails, the private workspace is kept and its path
is reported instead of deleting the only copy.

Validation failure returns nonzero and moves `review-requested` to
`blocked:review`. Read the diagnostic as untrusted reviewer output. Do not edit
it into a canonical review, delete findings, or reinterpret the verdict. After
addressing the reference problem, use the state tool to restore the recorded
`resumeState` (`review-requested`) and rerun the same canonical
`cross-model-review.sh` command for the same verified Head/packet. The opposite
reviewer must issue a fresh result; only a fully validated result/receipt pair
can advance the Issue. Retained diagnostics neither prevent a fresh run nor
replace current-Head verification if the implementation changes.

### Severity levels

- `critical`: データ消失、秘密漏えい、権限逸脱、主要機能不能
- `high`: 受け入れ条件違反、Crash、重大な誤動作
- `medium`: 実在する品質問題。今回のScopeで修正可能
- `low`: 非Blockingの改善提案

`approved`は、全ACが`supported`で、`findings`が空または`low`だけの場合に許可します。`low` findingは非Blockingの改善提案として内容を変更・削除せず保持します。`critical`、`high`、`medium`のfindingが一つでもある場合は`changes-requested`とします。

Reviewerは各 `AC-*` について `supported` または `unsupported` と証拠参照を返します。`unsupported` が一つでもあれば `approved` にできません。

`reviewPacketDigest` はreviewerが実際に読んだ `review-packet.json` の全byte列に対するSHA-256です。result publicationはこのdigestとcanonical packetのexact bytesが一致する間だけ行い、packet path、inode、bytesがpublication中に変われば失敗します。

Result schemaにrequester-controlledな「実行済み」fieldは追加しません。固定launcherはchild process完了とResult検証の後、別artifact `review-receipt.json` を発行します。receiptはschema version、Issue/Head、primary/opposite model、`cross-model-review.sh` と実際のreviewer launcherのpath/exact bytes digest、packet exact digest、validated result exact digest、published `review.json` exact digest、started/completed timestamp、exit status 0だけを持ちます。canonical reviewが先に存在しても、このexact receiptがなければレビュー実行済みとは扱いません。

## 5. Sealing interface

Packetは次で準備します。

```bash
tools/prepare-review-packet.sh \
  --primary codex \
  --issue 42 \
  --base-sha "${BASE_SHA}" \
  --head-sha "${HEAD_SHA}"
```

producerは `/usr/bin/git diff --binary --full-index --no-ext-diff --no-textconv --no-renames` の固定形でexact Base..Head `review.diff` を生成します。verifyの `visualEvaluation.cases[].images[]` をcase/image順に平坦化したpath/digestだけが `imageFiles` です。文書例外では空配列です。verify、画像、contract、repository test evidence、存在するrepository test planをsingle-linkかつno-followで開いたdescriptorをpublication完了まで保持し、path/inode/bytes、Git Head、actual diffをpublication前後で再検証します。`repositoryTests`と`repositoryTestPlan`はpacket内の値なので、review resultとpacketをsealする既存のexact-byte closureへそのまま含まれます。

pre-merge gateのdescriptor-owning callerは、まず次を呼びます。

```ruby
references = IOSTemplate::ReviewContract.strict_references!(
  packet_bytes: held_packet.bytes, issue: issue, head_sha: head_sha
)
```

返されたcanonical diff/verify/image leafをcaller自身が開いたまま保持し、最後に次を呼びます。

```ruby
IOSTemplate::ReviewContract.validate!(
  strict: true,
  packet_bytes: held_packet.bytes,
  result_bytes: held_result.bytes,
  verify_bytes: held_verify.bytes,
  contract_bytes: held_contract.bytes,
  diff_bytes: held_diff.bytes,
  image_bytes: ordered_held_image_bytes,
  repository_tests_bytes: held_repository_tests&.bytes,
  repository_test_plan_bytes: held_repository_test_plan&.bytes,
  revision_context: immutable_repository_revision_context,
  actual_diff_bytes: independently_generated_base_head_diff,
  primary: primary, issue: issue, base_sha: base_sha, head_sha: head_sha,
  require_temporal_order: true
)
```

このpure validation interfaceはartifact pathを再openしません。callerは戻り値を利用し終えるまでdescriptorを保持し、終了直前に各path identity/bytesを再検証します。strict modeはschema v1、bogus/empty diff、same-Head verify差し替え、画像差し替え、packet/result不一致をすべて拒否します。Gateはさらに `review-receipt.json` をsingle-link/no-followで保持し、current packet/review bytesとlauncher identityを照合します。

## 6. 呼び出し

- Codex primary -> Claudeを非対話read-onlyで呼ぶ
- Claude primary -> Codexをread-only sandboxで呼ぶ
- exactなユーザー承認宣言を持つCodex primary -> `cursor-grok-4.6-xhigh`を固定Cursor `ask` launcherで非対話read-only呼び出しする
- Timeout: 10分
- Reviewerはファイル編集、外部操作、commit、pushを行わない
- Reviewerが環境や認証状態を推測した場合、主エージェントは実環境で再確認する

Grok launcherはstdinを閉じ、GitHub／製品provider credentialを継承せず、exact modelを指定します。raw provider envelopeそのものは証拠ではなく、内側の完全なResultだけを正規化します。Cursorが`result`文字列の先頭へ短い進捗文を集約した場合は、16 KiB以下のvalid UTF-8 prefixにbrace／NULがなく、末尾からexactly oneの完全なJSON objectだけを一意にparseできるときに限りprefixを捨て、そのobject全体を通常validatorへ渡します。複数候補、途中JSON、trailing prose、不完全schemaは拒否し、prefixをartifactへ保存しません。認証identityとprovider telemetryもartifactへ保存しません。300KB級のdiffでも外側600秒timeoutより前に判断を完了できるよう、packet／sealed evidence、exact diffの変更production codeと対応test、必要時だけの追加sourceという順の480秒bounded passを指示し、deterministicなidentity／AC evidence scaffoldを渡します。scaffoldはverdict、finding、supported／unsupportedを決めず、判断不能なACはtimeoutまで探索せずvalidなchanges-requestedとして返させます。Reviewerの起動失敗、nonzero exit、timeout、空／不正JSON、schema／evidence不一致、write検出はcanonical review／receiptを発行せず `blocked:review` です。別モデルへの無断置換や主開発モデル自身の承認は行いません。
