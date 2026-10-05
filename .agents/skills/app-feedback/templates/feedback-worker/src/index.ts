import { DailyQuota, type QuotaResult } from "./daily-quota.ts";
import type { WorkerEnv } from "./env.ts";
import { githubAppAuth } from "./github-app-auth.ts";
import { createIssue, type GitHubAuth, type Send } from "./github.ts";
import { handleFeedback } from "./handler.ts";

export { DailyQuota };

export function makeWorker(options: { auth: (env: WorkerEnv) => GitHubAuth; send: Send }) {
  return {
    async fetch(request: Request, env: WorkerEnv): Promise<Response> {
      return handleFeedback(request, {
        limitSender: async (sender) => (await env.FEEDBACK_SENDER_LIMIT.limit({ key: sender })).success,
        consumeDaily: async (day) => {
          const quota = env.DAILY_QUOTA.get(env.DAILY_QUOTA.idFromName("global"));
          const response = await quota.fetch("https://daily-quota/consume", {
            method: "POST",
            body: JSON.stringify({ day }),
          });
          if (!response.ok) throw new Error(`daily quota answered ${response.status}`);
          return ((await response.json()) as { result: QuotaResult }).result;
        },
        createIssue: (content) =>
          createIssue(content, { repository: env.GITHUB_REPOSITORY, auth: options.auth(env), send: options.send }),
        now: () => new Date(),
      });
    },
  };
}

// Wrapped: calling the global fetch through another object throws "Illegal invocation" in Workers.
export default makeWorker({ auth: githubAppAuth, send: (input, init) => fetch(input, init) });
