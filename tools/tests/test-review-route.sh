#!/usr/bin/env bash
set -euo pipefail

source "${BASH_SOURCE[0]%${BASH_SOURCE[0]##*/}}lib/prerequisites.sh"
require_test_commands "$0" ruby

repo_root=$(cd "$(dirname "$0")/../.." && pwd -P)

ruby -I"$repo_root/tools/lib" <<'RUBY'
require "review-route"

def assert(value, message)
  raise message unless value
end

def contract(*texts)
  {
    "acceptanceCriteria" => texts.each_with_index.map do |text, index|
      {"id" => "AC-#{index + 1}", "text" => text}
    end
  }
end

route = IOSTemplate::ReviewRoute
assert(route.reviewer_for(contract: contract("ordinary AC"), primary: "codex") == "claude", "Codex default reviewer changed")
assert(route.reviewer_for(contract: contract("ordinary AC"), primary: "claude") == "codex", "Claude default reviewer changed")
assert(route.launcher_for(primary: "codex", reviewer: "claude") == "tools/cross-model-review.sh", "Claude launcher changed")
assert(route.launcher_for(primary: "claude", reviewer: "codex") == "tools/request-codex-review.sh", "Codex launcher changed")

declaration = "Opposite-review route: grok-fallback; Primary: codex; Reviewer: cursor-grok-4.6-xhigh; Approval: user-explicit; Reason: Claude is unavailable and the user approved this exact Issue."
grok_contract = contract("ordinary AC", declaration)
assert(route.reviewer_for(contract: grok_contract, primary: "codex") == "cursor-grok-4.6-xhigh", "authorized Grok route was not selected")
assert(route.launcher_for(primary: "codex", reviewer: "cursor-grok-4.6-xhigh") == "tools/request-grok-review.sh", "Grok launcher was not fixed")

invalid = [
  contract(declaration, declaration),
  contract(declaration.sub("cursor-grok-4.6-xhigh", "cursor-grok-4.6-high")),
  contract(declaration.sub("Primary: codex", "Primary: claude")),
  contract(declaration.sub("Approval: user-explicit", "Approval: inferred")),
  contract(declaration.sub(/Reason: .+/, "Reason: ")),
  contract("Opposite-review route: automatic; Primary: codex; Reviewer: cursor-grok-4.6-xhigh; Approval: user-explicit; Reason: no")
]
invalid.each do |value|
  begin
    route.reviewer_for(contract: value, primary: "codex")
    raise "invalid Grok route was accepted: #{value.inspect}"
  rescue IOSTemplate::ReviewRoute::ValidationError
    nil
  end
end

begin
  route.reviewer_for(contract: grok_contract, primary: "claude")
  raise "Grok route was accepted for a Claude primary"
rescue IOSTemplate::ReviewRoute::ValidationError
  nil
end

begin
  route.launcher_for(primary: "codex", reviewer: "grok")
  raise "an unpinned Grok alias was accepted"
rescue IOSTemplate::ReviewRoute::ValidationError
  nil
end
RUBY

echo 'PASS: sealed review routes preserve the default pair and allow only the user-approved exact Grok fallback'
