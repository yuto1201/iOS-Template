import { describe, test } from "node:test";
import assert from "node:assert/strict";
import { createIssue, GitHubError, type GitHubClient } from "../src/github.ts";

const content = { title: "[Bug] Crash", body: "## Feedback", labels: ["feedback", "bug"] };

function client(status: number, calls: { input: string; init: RequestInit }[]): GitHubClient {
  return {
    repository: "example-owner/GardenNotes-feedback",
    auth: { requestHeaders: async () => ({ "X-Test-Credential": "installation-123" }) },
    send: async (input, init) => {
      calls.push({ input, init });
      return new Response("{}", { status });
    },
  };
}

describe("createIssue", () => {
  test("posts the issue to the repository with the headers from GitHubAuth", async () => {
    const calls: { input: string; init: RequestInit }[] = [];
    await createIssue(content, client(201, calls));
    assert.equal(calls.length, 1);
    assert.equal(calls[0].input, "https://api.github.com/repos/example-owner/GardenNotes-feedback/issues");
    assert.equal(calls[0].init.method, "POST");
    assert.deepEqual(calls[0].init.headers, {
      "X-Test-Credential": "installation-123",
      Accept: "application/vnd.github+json",
      "Content-Type": "application/json",
      "User-Agent": "GardenNotes-feedback-worker",
      "X-GitHub-Api-Version": "2022-11-28",
    });
    assert.deepEqual(JSON.parse(String(calls[0].init.body)), content);
  });

  test("gives up on GitHub after a timeout instead of waiting for the platform limit", async () => {
    const calls: { input: string; init: RequestInit }[] = [];
    await createIssue(content, client(201, calls));
    assert.ok(calls[0].init.signal instanceof AbortSignal);
  });

  test("throws GitHubError with the status when GitHub does not create the issue", async () => {
    await assert.rejects(createIssue(content, client(422, [])), (error: unknown) => {
      assert.ok(error instanceof GitHubError);
      assert.equal(error.status, 422);
      return true;
    });
  });

  test("refuses an unconfigured repository before asking for credentials or calling GitHub", async () => {
    const calls: { input: string; init: RequestInit }[] = [];
    let credentialRequests = 0;
    for (const repository of ["{{GITHUB_REPOSITORY}}", "", "no-slash", "owner/name/extra"]) {
      const unconfigured: GitHubClient = {
        ...client(201, calls),
        repository,
        auth: { requestHeaders: async () => { credentialRequests += 1; return {}; } },
      };
      await assert.rejects(createIssue(content, unconfigured), /GITHUB_REPOSITORY is not configured/);
    }
    assert.equal(calls.length, 0);
    assert.equal(credentialRequests, 0);
  });

  test("passes a credential failure through without calling GitHub", async () => {
    const calls: { input: string; init: RequestInit }[] = [];
    const failing: GitHubClient = {
      ...client(201, calls),
      auth: { requestHeaders: async () => { throw new Error("no credential"); } },
    };
    await assert.rejects(createIssue(content, failing), /no credential/);
    assert.equal(calls.length, 0);
  });
});
