import type { QuotaResult } from "./daily-quota.ts";
import { parseSubmission, type ParseResult } from "./feedback.ts";
import { GitHubError } from "./github.ts";
import { issueContent, type IssueContent } from "./issue.ts";

export type FeedbackDeps = {
  /** Returns false when this sender already sent recently. */
  limitSender(sender: string): Promise<boolean>;
  /** Counts one issue for the UTC day, or reports the day's limit is used up. */
  consumeDaily(day: string): Promise<QuotaResult>;
  createIssue(content: IssueContent): Promise<void>;
  now(): Date;
};

export const maxRequestBytes = 8192;

export async function handleFeedback(request: Request, deps: FeedbackDeps): Promise<Response> {
  if (new URL(request.url).pathname !== "/v1/feedback") return failure(404, "not_found");
  if (request.method !== "POST") return failure(405, "method_not_allowed", { Allow: "POST" });
  if (!(await senderAllowed(request, deps))) return failure(429, "rate_limited");

  const text = await readBody(request);
  if (text === undefined) return failure(400, "invalid");
  let parsed: ParseResult;
  try {
    parsed = parseSubmission(JSON.parse(text));
  } catch {
    return failure(400, "invalid");
  }
  if (!parsed.ok) return failure(400, "invalid");

  let quota: QuotaResult;
  try {
    quota = await deps.consumeDaily(deps.now().toISOString().slice(0, 10));
  } catch {
    return failure(503, "unavailable");
  }
  if (quota === "exceeded") return failure(429, "rate_limited");
  // Fail closed on any other answer rather than create an issue past the cap.
  if (quota !== "ok") return failure(503, "unavailable");

  try {
    await deps.createIssue(issueContent(parsed.value));
  } catch (error) {
    // Never log the submission itself.
    console.error("feedback issue creation failed", error instanceof GitHubError ? error.status : kind(error));
    return failure(502, "upstream");
  }
  return Response.json({ status: "created" }, { status: 201 });
}

async function senderAllowed(request: Request, deps: FeedbackDeps): Promise<boolean> {
  // The address is only a limiter entry; it is never stored or logged.
  const sender = limiterEntry(request.headers.get("CF-Connecting-IP"));
  try {
    return await deps.limitSender(sender);
  } catch {
    // The binding is a best-effort guard; the daily quota still applies.
    console.error("feedback sender limiter failed");
    return true;
  }
}

/** The error's name only (for example GitHubAuthNotConfigured), never its message. */
function kind(error: unknown): string {
  return error instanceof Error ? error.name : "unknown";
}

/**
 * Reads at most 8KB. A body without Content-Length (chunked, or HTTP/2 and 3)
 * is streamed and cancelled as soon as it passes the cap, so an oversized
 * upload is never held in memory. A client that goes away mid-body gets 400.
 */
async function readBody(request: Request): Promise<string | undefined> {
  const declared = Number(request.headers.get("Content-Length") ?? "0");
  if (!Number.isFinite(declared) || declared > maxRequestBytes) return undefined;
  if (!request.body) return "";
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > maxRequestBytes) {
        await reader.cancel().catch(() => {});
        return undefined;
      }
      chunks.push(value);
    }
  } catch {
    return undefined;
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    return undefined;
  }
}

function failure(status: number, error: string, headers: Record<string, string> = {}): Response {
  return Response.json({ error }, { status, headers });
}

/**
 * The per-sender limiter entry. One IPv6 host usually owns a whole /64 and can
 * rotate addresses inside it, so IPv6 senders share their /64 prefix.
 */
export function limiterEntry(address: string | null): string {
  if (!address) return "unknown";
  if (!address.includes(":")) return address;
  // IPv4-mapped IPv6 (::ffff:198.51.100.4) is an IPv4 sender.
  if (address.includes(".")) return address.slice(address.lastIndexOf(":") + 1);
  let groups: string[];
  if (address.includes("::")) {
    const [head, tail] = address.split("::");
    const headGroups = head ? head.split(":") : [];
    const tailGroups = tail ? tail.split(":") : [];
    const zeros = Array(Math.max(0, 8 - headGroups.length - tailGroups.length)).fill("0");
    groups = [...headGroups, ...zeros, ...tailGroups];
  } else {
    groups = address.split(":");
  }
  const prefix = groups.slice(0, 4).map((group) => group.toLowerCase().replace(/^0+(?=.)/, ""));
  return `${prefix.join(":")}::/64`;
}
