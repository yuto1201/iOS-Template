import { describe, test } from "node:test";
import assert from "node:assert/strict";
import { GitHubError } from "../src/github.ts";
import { handleFeedback, limiterEntry, maxRequestBytes, type FeedbackDeps } from "../src/handler.ts";
import type { IssueContent } from "../src/issue.ts";

const submission = {
  category: "bug",
  body: "Secret household note",
  appVersion: "1.1",
  build: "5",
  osVersion: "27.0",
  deviceModel: "iPhone18,1",
  locale: "ja_JP",
};

type Recorder = { senders: string[]; days: string[]; issues: IssueContent[] };

function deps(overrides: Partial<FeedbackDeps> = {}): FeedbackDeps & { record: Recorder } {
  const record: Recorder = { senders: [], days: [], issues: [] };
  return {
    record,
    limitSender: async (sender) => {
      record.senders.push(sender);
      return true;
    },
    consumeDaily: async (day) => {
      record.days.push(day);
      return "ok";
    },
    createIssue: async (content) => {
      record.issues.push(content);
    },
    now: () => new Date("2026-09-25T08:00:00+09:00"),
    ...overrides,
  };
}

function post(body: string, headers: Record<string, string> = {}): Request {
  return new Request("https://feedback.example/v1/feedback", {
    method: "POST",
    headers: { "Content-Type": "application/json", "CF-Connecting-IP": "203.0.113.7", ...headers },
    body,
  });
}

describe("handleFeedback", () => {
  test("creates the issue and answers 201, counting the UTC day", async () => {
    const d = deps();
    const response = await handleFeedback(post(JSON.stringify(submission)), d);
    assert.equal(response.status, 201);
    assert.deepEqual(await response.json(), { status: "created" });
    assert.deepEqual(d.record.senders, ["203.0.113.7"]);
    assert.deepEqual(d.record.days, ["2026-09-24"]);
    assert.equal(d.record.issues.length, 1);
    assert.equal(d.record.issues[0].title, "[Bug] Secret household note");
  });

  test("answers 404 for other paths and 405 for other methods", async () => {
    const d = deps();
    const other = new Request("https://feedback.example/v1/other", { method: "POST", body: "{}" });
    assert.equal((await handleFeedback(other, d)).status, 404);
    const get = await handleFeedback(new Request("https://feedback.example/v1/feedback"), d);
    assert.equal(get.status, 405);
    assert.equal(get.headers.get("Allow"), "POST");
    assert.deepEqual(d.record, { senders: [], days: [], issues: [] });
  });

  test("answers 429 when the sender is limited, before reading anything else", async () => {
    const d = deps({ limitSender: async () => false });
    const response = await handleFeedback(post(JSON.stringify(submission)), d);
    assert.equal(response.status, 429);
    assert.deepEqual(await response.json(), { error: "rate_limited" });
    assert.deepEqual(d.record.days, []);
    assert.deepEqual(d.record.issues, []);
  });

  test("lets the request through when the sender limit cannot be checked", async () => {
    const d = deps({ limitSender: async () => { throw new Error("binding unavailable"); } });
    assert.equal((await handleFeedback(post(JSON.stringify(submission)), d)).status, 201);
  });

  test("uses one shared limiter entry when the sender address is missing", async () => {
    const d = deps();
    const request = new Request("https://feedback.example/v1/feedback", { method: "POST", body: JSON.stringify(submission) });
    assert.equal((await handleFeedback(request, d)).status, 201);
    assert.deepEqual(d.record.senders, ["unknown"]);
  });

  test("answers 400 without reading the body when the declared size is over 8KB", async () => {
    const d = deps();
    let read = false;
    const request = {
      url: "https://feedback.example/v1/feedback",
      method: "POST",
      headers: new Headers({ "Content-Length": String(maxRequestBytes + 1) }),
      arrayBuffer: async () => {
        read = true;
        return new ArrayBuffer(0);
      },
    } as unknown as Request;
    assert.equal((await handleFeedback(request, d)).status, 400);
    assert.equal(read, false);
    assert.deepEqual(d.record.days, []);
  });

  test("answers 400 when the actual body is over 8KB", async () => {
    const d = deps();
    // Valid apart from its size: the body trims to "x", so only the byte cap can reject it.
    const oversized = JSON.stringify({ ...submission, body: "x" + " ".repeat(maxRequestBytes) });
    assert.equal((await handleFeedback(post(oversized), d)).status, 400);
    assert.deepEqual(d.record.days, []);
  });

  test("stops reading an undeclared body once it passes 8KB", async () => {
    const d = deps();
    const chunk = new Uint8Array(1024).fill(0x20);
    let pulled = 0;
    const stream = new ReadableStream({
      pull(controller) {
        if (pulled >= 1024 * 1024) {
          controller.close();
          return;
        }
        pulled += chunk.byteLength;
        controller.enqueue(chunk);
      },
    });
    const request = new Request("https://feedback.example/v1/feedback", {
      method: "POST",
      body: stream,
      duplex: "half",
    } as RequestInit);
    assert.equal((await handleFeedback(request, d)).status, 400);
    assert.ok(pulled <= maxRequestBytes + 4 * 1024, `read ${pulled} bytes`);
    assert.deepEqual(d.record.days, []);
  });

  test("answers 400 when the client goes away mid-body", async () => {
    const d = deps();
    const stream = new ReadableStream({
      pull(controller) {
        controller.error(new Error("connection lost"));
      },
    });
    const request = new Request("https://feedback.example/v1/feedback", {
      method: "POST",
      body: stream,
      duplex: "half",
    } as RequestInit);
    assert.equal((await handleFeedback(request, d)).status, 400);
  });

  test("limits IPv6 senders by their /64 prefix", async () => {
    const d = deps();
    const request = post(JSON.stringify(submission), { "CF-Connecting-IP": "2001:db8:1:2:aaaa::1" });
    assert.equal((await handleFeedback(request, d)).status, 201);
    assert.deepEqual(d.record.senders, ["2001:db8:1:2::/64"]);
  });

  test("answers 400 for malformed JSON, invalid UTF-8, and invalid content without using the daily quota", async () => {
    const d = deps();
    assert.equal((await handleFeedback(post("{"), d)).status, 400);
    const invalidUTF8 = new Request("https://feedback.example/v1/feedback", {
      method: "POST",
      body: new Uint8Array([0x7b, 0xff, 0x7d]),
    });
    assert.equal((await handleFeedback(invalidUTF8, d)).status, 400);
    const invalid = await handleFeedback(post(JSON.stringify({ ...submission, body: "" })), d);
    assert.equal(invalid.status, 400);
    assert.deepEqual(await invalid.json(), { error: "invalid" });
    assert.deepEqual(d.record.days, []);
    assert.deepEqual(d.record.issues, []);
  });

  test("answers 503 and creates nothing when the daily quota cannot be counted", async () => {
    const d = deps({ consumeDaily: async () => { throw new Error("quota down"); } });
    const response = await handleFeedback(post(JSON.stringify(submission)), d);
    assert.equal(response.status, 503);
    assert.deepEqual(await response.json(), { error: "unavailable" });
    assert.deepEqual(d.record.issues, []);
  });

  test("answers 429 and creates nothing when the daily quota is used up", async () => {
    const d = deps({ consumeDaily: async () => "exceeded" });
    assert.equal((await handleFeedback(post(JSON.stringify(submission)), d)).status, 429);
    assert.deepEqual(d.record.issues, []);
  });

  test("answers 502 when GitHub fails, and logs only the status", async (t) => {
    const logged = t.mock.method(console, "error", () => {});
    const d = deps({ createIssue: async () => { throw new GitHubError(500); } });
    const response = await handleFeedback(post(JSON.stringify(submission)), d);
    assert.equal(response.status, 502);
    assert.deepEqual(await response.json(), { error: "upstream" });
    assert.equal(logged.mock.callCount(), 1);
    const line = JSON.stringify(logged.mock.calls[0].arguments);
    assert.ok(line.includes("500"));
    assert.ok(!line.includes("Secret household note"));
  });

  test("answers 503 and creates nothing when the daily counter gives an unknown answer", async () => {
    const d = deps({ consumeDaily: async () => "maybe" as never });
    const response = await handleFeedback(post(JSON.stringify(submission)), d);
    assert.equal(response.status, 503);
    assert.deepEqual(d.record.issues, []);
  });

  test("logs a failed sender limiter without the address and still accepts", async (t) => {
    const logged = t.mock.method(console, "error", () => {});
    const d = deps({ limitSender: async () => { throw new Error("binding down"); } });
    assert.equal((await handleFeedback(post(JSON.stringify(submission)), d)).status, 201);
    assert.equal(logged.mock.callCount(), 1);
    assert.ok(!JSON.stringify(logged.mock.calls[0].arguments).includes("203.0.113"));
  });

  test("logs the kind of a non-GitHub failure, such as unconfigured credentials", async (t) => {
    const logged = t.mock.method(console, "error", () => {});
    const failure = new Error("placeholder");
    failure.name = "GitHubAuthNotConfigured";
    const d = deps({ createIssue: async () => { throw failure; } });
    assert.equal((await handleFeedback(post(JSON.stringify(submission)), d)).status, 502);
    assert.ok(JSON.stringify(logged.mock.calls[0].arguments).includes("GitHubAuthNotConfigured"));
  });

  test("answers 502 when the GitHub credentials cannot be obtained", async (t) => {
    t.mock.method(console, "error", () => {});
    const d = deps({ createIssue: async () => { throw new Error("no credential"); } });
    assert.equal((await handleFeedback(post(JSON.stringify(submission)), d)).status, 502);
  });
});

describe("limiterEntry", () => {
  test("keeps IPv4, groups IPv6 by its /64, and unwraps IPv4-mapped addresses", () => {
    assert.equal(limiterEntry("203.0.113.7"), "203.0.113.7");
    assert.equal(limiterEntry(null), "unknown");
    assert.equal(limiterEntry("2001:db8:1:2:aaaa::1"), "2001:db8:1:2::/64");
    assert.equal(limiterEntry("2001:0DB8:0001:0002:bbbb:cccc:dddd:eeee"), "2001:db8:1:2::/64");
    assert.equal(limiterEntry("2001:db8::1"), "2001:db8:0:0::/64");
    assert.equal(limiterEntry("::ffff:198.51.100.4"), "198.51.100.4");
  });
});
