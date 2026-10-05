import type { IssueContent } from "./issue.ts";

/**
 * Supplies the headers that authenticate a request as the GitHub App installation.
 * Implemented in github-app-auth.ts.
 */
export interface GitHubAuth {
  requestHeaders(): Promise<Record<string, string>>;
}

export type Send = (input: string, init: RequestInit) => Promise<Response>;

/** GitHub normally answers in well under a second; stop waiting long before the platform limit. */
export const gitHubTimeoutMilliseconds = 10_000;

export type GitHubClient = {
  repository: string;
  auth: GitHubAuth;
  send: Send;
};

const repositoryPattern = /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\/[A-Za-z0-9._-]{1,100}$/;

/**
 * The app's feedback repository, `<owner>/<name>`, from the Workers config. An unrendered template
 * placeholder or any other malformed value fails before anything is sent to GitHub.
 */
export function repositoryName(repository: string): string {
  if (!repositoryPattern.test(repository)) throw new Error("GITHUB_REPOSITORY is not configured");
  return repository.slice(repository.indexOf("/") + 1);
}

/** Each app's Worker identifies itself by its own feedback repository. */
export function userAgent(repository: string): string {
  return `${repositoryName(repository)}-worker`;
}

export class GitHubError extends Error {
  status: number;

  constructor(status: number) {
    super(`GitHub responded with ${status}`);
    this.name = "GitHubError";
    this.status = status;
  }
}

export async function createIssue(content: IssueContent, client: GitHubClient): Promise<void> {
  const agent = userAgent(client.repository);
  const credentials = await client.auth.requestHeaders();
  const response = await client.send(`https://api.github.com/repos/${client.repository}/issues`, {
    method: "POST",
    headers: {
      ...credentials,
      Accept: "application/vnd.github+json",
      "Content-Type": "application/json",
      "User-Agent": agent,
      "X-GitHub-Api-Version": "2022-11-28",
    },
    body: JSON.stringify(content),
    signal: AbortSignal.timeout(gitHubTimeoutMilliseconds),
  });
  if (response.status !== 201) throw new GitHubError(response.status);
}
