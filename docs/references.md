# Official references

設計時に確認した公式資料です。外部サービスやCLIの挙動は変化するため、実際の操作直前にCodexが再確認します。

## Codex

- [Custom instructions with AGENTS.md](https://learn.chatgpt.com/docs/agent-configuration/agents-md)
- [Skills](https://learn.chatgpt.com/docs/customization/skills)
- [Subagents and project-scoped custom agents](https://learn.chatgpt.com/docs/agent-configuration/subagents)

Codexの共有プロジェクトスキルは `.agents/skills/`、プロジェクト固有のカスタムエージェントは `.codex/agents/` に置きます。

## Claude Code

- [Hooks reference](https://code.claude.com/docs/en/hooks)
- [Create custom subagents](https://code.claude.com/docs/en/sub-agents)
- [Extend Claude with skills](https://code.claude.com/docs/en/skills)

Claude CodeのプロジェクトHookは `.claude/settings.json`、エージェントは `.claude/agents/`、スキルは `.claude/skills/` に置けます。Claude Codeがスキルのシンボリックリンクを解決できることを利用し、共有スキルの正本を一つにします。

## Supabase

- [Local development with schema migrations](https://supabase.com/docs/guides/local-development/overview)
- [Local development workflow](https://supabase.com/docs/guides/local-development/cli-workflows)
- [Database migrations](https://supabase.com/docs/guides/deployment/database-migrations)
- [API keys](https://supabase.com/docs/guides/getting-started/api-keys)
- [Row Level Security](https://supabase.com/docs/guides/database/postgres/row-level-security)
- [Managing environments](https://supabase.com/docs/guides/deployment/managing-environments)

Supabaseのリモートスキーマ変更はmigration-firstで行い、公開クライアントにはPublishable Keyだけを使用します。

## GitHub CLI

- [GitHub CLI manual](https://cli.github.com/manual/)
- [gh pr merge](https://cli.github.com/manual/gh_pr_merge)

マージ時はSquashとHead SHA照合を使用し、Cleanup対象はIssue状態から明示的に解決します。
