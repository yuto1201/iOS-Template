#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd -P); tmp=$(mktemp -d "${TMPDIR:-/tmp}/merge-e2e.XXXXXX"); trap 'rm -rf "$tmp"' EXIT
remote="$tmp/r.git"; primary="$tmp/repo"; wt="$primary/.worktrees/42-merge-e2e"; git init --bare "$remote" >/dev/null; git init -b main "$primary" >/dev/null; git -C "$primary" config user.name f; git -C "$primary" config user.email f@e.invalid; echo x > "$primary/README.md"; git -C "$primary" add README.md; git -C "$primary" commit -m base >/dev/null; git -C "$primary" remote add origin "$remote"; git -C "$primary" push origin main >/dev/null; mkdir -p "$primary/.worktrees"; git -C "$primary" worktree add -b codex/42-merge-e2e "$wt" main >/dev/null
cp -R "$root/tools" "$wt/"; cp -R "$root/Config" "$wt/"; ln -s ../../.artifacts "$wt/.artifacts"; mkdir -p "$primary/.artifacts/issues/42/$(git -C "$wt" rev-parse HEAD)"; h=$(git -C "$wt" rev-parse HEAD); d=sha256:$(printf x | shasum -a 256 | awk '{print $1}')
printf '{"issue":42,"headSha":"%s","verifySha":"%s","issueContractDigest":"%s","verdict":"approved","findings":[]}' "$h" "$h" "$d" > "$primary/.artifacts/issues/42/$h/review.json"
printf '{"issue":42,"headSha":"%s","issueContract":{"digest":"%s"},"status":"passed","acceptanceEvidence":[]}' "$h" "$d" > "$primary/.artifacts/issues/42/$h/verify.json"
printf '{"issue":42,"repository":"yuto1201/iOS-Template","acceptanceCriteria":[],"schemaVersion":1}' > "$primary/.artifacts/issues/42/issue-contract.json"
printf '{"schemaVersion":1,"issue":42,"repository":"yuto1201/iOS-Template","branch":"codex/42-merge-e2e","worktree":".worktrees/42-merge-e2e","baseSha":"%s","primaryImplementer":"codex","issueContract":{"path":".artifacts/issues/42/issue-contract.json","digest":"%s"},"state":"approved-for-merge","previousState":"review-requested","resumeState":null,"executor":"codex"}' "$(git -C "$primary" rev-parse main)" "$d" > "$primary/.artifacts/issues/42/state.json"
mv "$wt/tools/premerge-gate.sh" "$wt/tools/premerge-gate.real"; printf '#!/usr/bin/env bash\nprintf "{\\"status\\":\\"passed\\"}\\n"\n' > "$wt/tools/premerge-gate.sh"; chmod +x "$wt/tools/premerge-gate.sh"
mkdir "$tmp/bin"; cat > "$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -e; echo "$*" >> "$GHLOG"; case "$1 $2" in 'auth status') echo 'account yuto1201';; 'repo view') echo '{"nameWithOwner":"yuto1201/iOS-Template","defaultBranchRef":{"name":"main"},"url":"https://github.com/yuto1201/iOS-Template"}';; 'pr list') echo "${PRS:-[]}";; 'pr create') export PRS='[{"number":57,"state":"OPEN","headRefName":"codex/42-merge-e2e","headRefOid":"'"$HEAD"'"}]'; echo "$PRS" > "$PRFILE";; 'pr merge') echo '[{"number":57,"state":"MERGED","headRefName":"codex/42-merge-e2e","headRefOid":"'"$HEAD"'"}]' > "$PRFILE";; 'pr view') echo '{"state":"MERGED","headRefOid":"'"$HEAD"'","mergeCommit":{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}';; 'issue view') echo '{"state":"CLOSED","labels":[{"name":"state:approved-for-merge"}],"comments":[]}' ;; 'issue edit'|'issue comment') :;; *) exit 2;; esac
EOF
chmod +x "$tmp/bin/gh"; export PATH="$tmp/bin:$PATH" GHLOG="$tmp/gh.log" HEAD="$h" PRFILE="$tmp/prs"; export PRS='[]'
(cd "$wt" && tools/merge-issue.sh --repo yuto1201/iOS-Template --issue 42 >/dev/null) || true
grep -Fq 'pr create' "$tmp/gh.log"; grep -Fq "pr merge 57 --repo yuto1201/iOS-Template --squash --match-head-commit $h" "$tmp/gh.log"
echo 'PASS: merge command formation fixture'
