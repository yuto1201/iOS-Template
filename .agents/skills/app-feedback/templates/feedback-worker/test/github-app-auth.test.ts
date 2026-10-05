import { describe, test } from "node:test";
import assert from "node:assert/strict";
import type { WorkerEnv } from "../src/env.ts";
import { githubAppAuth } from "../src/github-app-auth.ts";

const keys = await crypto.subtle.generateKey(
  { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
  true, ["sign", "verify"],
);
const pkcs8 = await crypto.subtle.exportKey("pkcs8", keys.privateKey);
const pem = `-----BEGIN PRIVATE KEY-----\n${Buffer.from(pkcs8).toString("base64").match(/.{1,64}/g)!.join("\n")}\n-----END PRIVATE KEY-----`;
const start = Date.parse("2026-09-28T00:00:00Z");

function environment(repository = "example-owner/GardenNotes-feedback"): WorkerEnv {
  return {
    GITHUB_REPOSITORY: repository,
    GITHUB_APP_ID: "12345",
    GITHUB_APP_INSTALLATION_ID: "67890",
    GITHUB_APP_SIGNING_PKCS8: pem,
  } as WorkerEnv;
}

function response(token: string, expiresAt: number): Response {
  return Response.json({ token, expires_at: new Date(expiresAt).toISOString() }, { status: 201 });
}

function decodeBase64url(value: string): Uint8Array {
  return new Uint8Array(Buffer.from(value, "base64url"));
}

describe("githubAppAuth", () => {
  test("signs an RS256 App JWT and requests a repository-scoped installation token", async () => {
    const calls: { input: string; init: RequestInit }[] = [];
    const auth = githubAppAuth(environment(), async (input, init) => {
      calls.push({ input, init });
      return response("installation-token", start + 60 * 60_000);
    }, () => new Date(start));

    assert.deepEqual(await auth.requestHeaders(), { Authorization: "Bearer installation-token" });
    assert.equal(calls.length, 1);
    assert.equal(calls[0].input, "https://api.github.com/app/installations/67890/access_tokens");
    assert.equal(calls[0].init.method, "POST");
    assert.deepEqual(JSON.parse(String(calls[0].init.body)), {
      permissions: { issues: "write" }, repositories: ["GardenNotes-feedback"],
    });
    assert.ok(calls[0].init.signal instanceof AbortSignal);
    const headers = calls[0].init.headers as Record<string, string>;
    assert.equal(headers.Accept, "application/vnd.github+json");
    assert.equal(headers["Content-Type"], "application/json");
    assert.equal(headers["X-GitHub-Api-Version"], "2022-11-28");
    assert.equal(headers["User-Agent"], "GardenNotes-feedback-worker");

    const [encodedHeader, encodedClaims, encodedSignature] = headers.Authorization.replace(/^Bearer /, "").split(".");
    assert.deepEqual(JSON.parse(Buffer.from(decodeBase64url(encodedHeader)).toString()), { alg: "RS256", typ: "JWT" });
    assert.deepEqual(JSON.parse(Buffer.from(decodeBase64url(encodedClaims)).toString()), {
      iat: Math.floor(start / 1000) - 60,
      exp: Math.floor(start / 1000) + 9 * 60,
      iss: "12345",
    });
    assert.equal(await crypto.subtle.verify(
      "RSASSA-PKCS1-v1_5", keys.publicKey, decodeBase64url(encodedSignature),
      new TextEncoder().encode(`${encodedHeader}.${encodedClaims}`),
    ), true);
  });

  test("scopes the token and User-Agent to the configured repository, not a fixed app", async () => {
    const calls: { input: string; init: RequestInit }[] = [];
    const auth = githubAppAuth(environment("acme/OtherApp-feedback"), async (input, init) => {
      calls.push({ input, init });
      return response("other-token", start + 60 * 60_000);
    }, () => new Date(start));
    await auth.requestHeaders();
    assert.deepEqual(JSON.parse(String(calls[0].init.body)).repositories, ["OtherApp-feedback"]);
    assert.equal((calls[0].init.headers as Record<string, string>)["User-Agent"], "OtherApp-feedback-worker");
  });

  test("does not contact GitHub while the repository is still the template placeholder", async () => {
    let calls = 0;
    const auth = githubAppAuth(environment("{{GITHUB_REPOSITORY}}"), async () => {
      calls += 1;
      return response("never", start + 60 * 60_000);
    }, () => new Date(start));
    await assert.rejects(auth.requestHeaders(), /GITHUB_REPOSITORY is not configured/);
    assert.equal(calls, 0);
  });

  test("shares a token across auth calls and refreshes it five minutes before expiration", async () => {
    const env = environment();
    let current = start;
    let exchanges = 0;
    const send = async () => response(`token-${++exchanges}`, start + 60 * 60_000);
    assert.deepEqual(await githubAppAuth(env, send, () => new Date(current)).requestHeaders(), { Authorization: "Bearer token-1" });
    current = start + 55 * 60_000 - 1;
    assert.deepEqual(await githubAppAuth(env, send, () => new Date(current)).requestHeaders(), { Authorization: "Bearer token-1" });
    assert.equal(exchanges, 1);
    current += 1;
    assert.deepEqual(await githubAppAuth(env, send, () => new Date(current)).requestHeaders(), { Authorization: "Bearer token-2" });
    assert.equal(exchanges, 2);
  });

  test("does not contact GitHub when any credential is missing", async () => {
    let calls = 0;
    for (const name of ["GITHUB_APP_ID", "GITHUB_APP_INSTALLATION_ID", "GITHUB_APP_SIGNING_PKCS8"] as const) {
      const env = environment();
      env[name] = " ";
      const auth = githubAppAuth(env, async () => { calls++; return response("token", start + 60 * 60_000); });
      await assert.rejects(auth.requestHeaders(), /not configured/);
    }
    assert.equal(calls, 0);
  });

  test("throws on an unsuccessful exchange without caching it", async () => {
    const env = environment();
    let calls = 0;
    const auth = githubAppAuth(env, async () => {
      calls++;
      return calls === 1 ? new Response("denied", { status: 403 }) : response("recovered", start + 60 * 60_000);
    }, () => new Date(start));
    await assert.rejects(auth.requestHeaders(), /exchange failed \(403\)/);
    assert.deepEqual(await auth.requestHeaders(), { Authorization: "Bearer recovered" });
    assert.equal(calls, 2);
  });

  test("rejects an invalid token response", async () => {
    const auth = githubAppAuth(environment(), async () => Response.json({ token: "", expires_at: "not-a-date" }, { status: 201 }));
    await assert.rejects(auth.requestHeaders(), /invalid credentials/);
  });

  test("coalesces concurrent exchanges for the same Worker environment", async () => {
    const env = environment();
    let calls = 0;
    const send = async () => {
      calls++;
      await new Promise((resolve) => setTimeout(resolve, 10));
      return response("shared", start + 60 * 60_000);
    };
    const auth = githubAppAuth(env, send, () => new Date(start));
    const headers = await Promise.all([auth.requestHeaders(), auth.requestHeaders()]);
    assert.deepEqual(headers, [{ Authorization: "Bearer shared" }, { Authorization: "Bearer shared" }]);
    assert.equal(calls, 1);
  });
});
