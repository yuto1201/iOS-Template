import { describe, test } from "node:test";
import assert from "node:assert/strict";
import type { WorkerEnv } from "../src/env.ts";
import { makeWorker } from "../src/index.ts";

const submission = {
  category: "other",
  body: "Thanks for the app",
  appVersion: "1.1",
  build: "5",
  osVersion: "27.0",
  deviceModel: "iPhone18,1",
  locale: "en_US",
};

function environment(quotaStatus = 200) {
  const calls = { limiterEntries: [] as string[], quotaNames: [] as string[], quotaBodies: [] as string[] };
  const env: WorkerEnv = {
    FEEDBACK_SENDER_LIMIT: {
      limit: async ({ key: entry }) => {
        calls.limiterEntries.push(entry);
        return { success: true };
      },
    },
    DAILY_QUOTA: {
      idFromName: (name) => {
        calls.quotaNames.push(name);
        return name;
      },
      get: () => ({
        fetch: async (_input, init) => {
          calls.quotaBodies.push(String(init?.body));
          return quotaStatus === 200 ? Response.json({ result: "ok" }) : new Response(null, { status: quotaStatus });
        },
      }),
    },
    GITHUB_REPOSITORY: "example-owner/GardenNotes-feedback",
  };
  return { env, calls };
}

function post(): Request {
  return new Request("https://feedback.example/v1/feedback", {
    method: "POST",
    headers: { "CF-Connecting-IP": "198.51.100.4" },
    body: JSON.stringify(submission),
  });
}

const testAuth = () => ({ requestHeaders: async () => ({ "X-Test-Credential": "installation-1" }) });

describe("worker entry", () => {
  test("wires the limiter, the global quota, and GitHub together", async () => {
    const sent: string[] = [];
    const worker = makeWorker({
      auth: testAuth,
      send: async (input) => {
        sent.push(input);
        return new Response("{}", { status: 201 });
      },
    });
    const { env, calls } = environment();
    const response = await worker.fetch(post(), env);
    assert.equal(response.status, 201);
    assert.deepEqual(calls.limiterEntries, ["198.51.100.4"]);
    assert.deepEqual(calls.quotaNames, ["global"]);
    assert.match(calls.quotaBodies[0], /^\{"day":"\d{4}-\d{2}-\d{2}"\}$/);
    assert.deepEqual(sent, ["https://api.github.com/repos/example-owner/GardenNotes-feedback/issues"]);
  });

  test("answers 503 when the quota object fails", async () => {
    const worker = makeWorker({ auth: testAuth, send: async () => new Response("{}", { status: 201 }) });
    const { env } = environment(500);
    assert.equal((await worker.fetch(post(), env)).status, 503);
  });
});
