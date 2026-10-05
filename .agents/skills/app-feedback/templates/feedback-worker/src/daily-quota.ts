/** The subset of Durable Object storage the quota uses. */
export type QuotaStorage = {
  get(name: string): Promise<unknown>;
  put(name: string, value: unknown): Promise<void>;
};

export type QuotaResult = "ok" | "exceeded";

type QuotaState = { day: string; count: number };

export const defaultDailyLimit = 100;
const stateName = "quota";
const dayPattern = /^\d{4}-\d{2}-\d{2}$/;

/**
 * Counts one issue for `day` (UTC, YYYY-MM-DD) unless the day already reached
 * `limit`. A request that still carries the previous day (sent around midnight)
 * counts toward the stored day instead of resetting it.
 */
export async function consumeDailyQuota(storage: QuotaStorage, day: string, limit: number): Promise<QuotaResult> {
  const stored = (await storage.get(stateName)) as QuotaState | undefined;
  const current = stored && stored.day >= day ? stored : { day, count: 0 };
  if (current.count >= limit) return "exceeded";
  await storage.put(stateName, { day: current.day, count: current.count + 1 });
  return "ok";
}

/** A whole number from the config; 0 closes intake. Anything else uses the default. */
export function dailyLimit(raw: string | undefined): number {
  if (raw === undefined || raw.trim() === "") return defaultDailyLimit;
  const value = Number(raw);
  return Number.isInteger(value) && value >= 0 ? value : defaultDailyLimit;
}

/**
 * One instance (named "global") counts every issue the Worker creates.
 * Durable Objects run one request at a time, and there is no other I/O between
 * the read and the write, so the count cannot race.
 */
export class DailyQuota {
  storage: QuotaStorage;
  limit: number;

  constructor(state: { storage: QuotaStorage }, env: { DAILY_ISSUE_LIMIT?: string }) {
    this.storage = state.storage;
    this.limit = dailyLimit(env.DAILY_ISSUE_LIMIT);
  }

  async fetch(request: Request): Promise<Response> {
    let day: unknown;
    try {
      day = ((await request.json()) as { day?: unknown }).day;
    } catch {
      return new Response(null, { status: 400 });
    }
    if (typeof day !== "string" || !dayPattern.test(day)) return new Response(null, { status: 400 });
    return Response.json({ result: await consumeDailyQuota(this.storage, day, this.limit) });
  }
}
