#!/usr/bin/env bash
set -u

project_dir=${CLAUDE_PROJECT_DIR:-}
agents_file="$project_dir/AGENTS.md"

if [[ -z "$project_dir" || ! -f "$agents_file" ]]; then
  builtin printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"AGENTS.md is unavailable. Stop with blocked:environment and restore the repository contract before continuing."}}'
  exit 0
fi

RUBYOPT='' RUBYLIB='' /usr/bin/ruby --disable-gems -rjson - "$agents_file" <<'RUBY'
path = ARGV.fetch(0)
content = File.binread(path)
context =
  if content.bytesize > 32_768
    "AGENTS.md exceeds 32768 bytes. Stop with blocked:environment; do not continue without the complete repository contract."
  else
    content.force_encoding(Encoding::UTF_8)
    if content.valid_encoding?
      content
    else
      "AGENTS.md is not valid UTF-8. Stop with blocked:environment; do not continue without a readable repository contract."
    end
  end

STDOUT.write(JSON.generate({
  "hookSpecificOutput" => {
    "hookEventName" => "SessionStart",
    "additionalContext" => context
  }
}))
STDOUT.write("\n")
RUBY
