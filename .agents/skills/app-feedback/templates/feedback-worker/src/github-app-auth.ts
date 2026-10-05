import type { WorkerEnv } from "./env.ts";
import { gitHubTimeoutMilliseconds, repositoryName, userAgent, type GitHubAuth, type Send } from "./github.ts";

type InstallationToken = { token: string; expiresAt: number };

// The Worker reuses this module between requests. Keying by its bindings also keeps
// different environments and signing credentials from sharing an installation token.
const tokenCache = new WeakMap<WorkerEnv, InstallationToken>();
const pendingTokens = new WeakMap<WorkerEnv, Promise<InstallationToken>>();

function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function pemBytes(pem: string): Uint8Array {
  const match = /^-----BEGIN PRIVATE KEY-----\s+([A-Za-z0-9+/=\s]+)\s+-----END PRIVATE KEY-----\s*$/.exec(pem);
  if (!match) throw new Error("GitHub App signing key is invalid");
  return Uint8Array.from(atob(match[1].replace(/\s/g, "")), (character) => character.charCodeAt(0));
}

async function appJwt(appId: string, pem: string, now: Date): Promise<string> {
  const key = await crypto.subtle.importKey(
    "pkcs8", pemBytes(pem).buffer as ArrayBuffer,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"],
  );
  const issuedAt = Math.floor(now.getTime() / 1000);
  const encoder = new TextEncoder();
  const message = [
    base64url(encoder.encode(JSON.stringify({ alg: "RS256", typ: "JWT" }))),
    base64url(encoder.encode(JSON.stringify({ iat: issuedAt - 60, exp: issuedAt + 9 * 60, iss: appId }))),
  ].join(".");
  const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, encoder.encode(message));
  return `${message}.${base64url(new Uint8Array(signature))}`;
}

export function githubAppAuth(
  env: WorkerEnv,
  send: Send = (input, init) => fetch(input, init),
  now: () => Date = () => new Date(),
): GitHubAuth {
  return {
    async requestHeaders(): Promise<Record<string, string>> {
      const appId = env.GITHUB_APP_ID?.trim();
      const installationId = env.GITHUB_APP_INSTALLATION_ID?.trim();
      const signingKey = env.GITHUB_APP_SIGNING_PKCS8?.trim();
      if (!appId || !installationId || !signingKey) throw new Error("GitHub App credentials are not configured");
      // The installation token covers only this app's feedback repository.
      const repository = repositoryName(env.GITHUB_REPOSITORY);
      const agent = userAgent(env.GITHUB_REPOSITORY);

      const currentTime = now().getTime();
      const cached = tokenCache.get(env);
      if (cached && currentTime < cached.expiresAt - 5 * 60_000) {
        return { Authorization: `Bearer ${cached.token}` };
      }

      let pending = pendingTokens.get(env);
      if (!pending) {
        pending = (async (): Promise<InstallationToken> => {
          const jwt = await appJwt(appId, signingKey, now());
          const response = await send(`https://api.github.com/app/installations/${installationId}/access_tokens`, {
            method: "POST",
            headers: {
              Accept: "application/vnd.github+json",
              Authorization: `Bearer ${jwt}`,
              "Content-Type": "application/json",
              "User-Agent": agent,
              "X-GitHub-Api-Version": "2022-11-28",
            },
            body: JSON.stringify({ permissions: { issues: "write" }, repositories: [repository] }),
            signal: AbortSignal.timeout(gitHubTimeoutMilliseconds),
          });
          if (response.status !== 201) throw new Error(`GitHub App token exchange failed (${response.status})`);
          const result: unknown = await response.json();
          if (typeof result !== "object" || result === null || !("token" in result) ||
              !("expires_at" in result) || typeof result.token !== "string" || !result.token ||
              typeof result.expires_at !== "string") {
            throw new Error("GitHub App token exchange returned invalid credentials");
          }
          const expiresAt = Date.parse(result.expires_at);
          if (!Number.isFinite(expiresAt) || expiresAt <= now().getTime()) {
            throw new Error("GitHub App token exchange returned an invalid expiration");
          }
          const token = { token: result.token, expiresAt };
          tokenCache.set(env, token);
          return token;
        })();
        pendingTokens.set(env, pending);
      }
      try {
        const { token } = await pending;
        return { Authorization: `Bearer ${token}` };
      } finally {
        if (pendingTokens.get(env) === pending) pendingTokens.delete(env);
      }
    },
  };
}
