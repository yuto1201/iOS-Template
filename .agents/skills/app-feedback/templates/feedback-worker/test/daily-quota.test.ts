import { describe, test } from "node:test";
import assert from "node:assert/strict";
import { consumeDailyQuota, dailyLimit, DailyQuota, type QuotaStorage } from "../src/daily-quota.ts";

function memoryStorage(): QuotaStorage & { writes: number } {
  const values = new Map<string, unknown>();
  const storage = {
    writes: 0,
    get: async (name: string) => values.get(name),
    put: async (name: string, value: unknown) => {
      storage.writes += 1;
      values.set(name, value);
    },
  };
  return storage;
}

function consumeRequest(day: unknown): Request {
  return new Request("https://daily-quota/consume", { method: "POST", body: JSON.stringify({ day }) });
}

describe("consumeDailyQuota", () => {
  test("allows the limit, then refuses without writing", async () => {
    const storage = memoryStorage();
    for (let index = 0; index < 3; index += 1) {
      assert.equal(await consumeDailyQuota(storage, "2026-09-24", 3), "ok");
    }
    assert.equal(await consumeDailyQuota(storage, "2026-09-24", 3), "exceeded");
    assert.equal(storage.writes, 3);
  });

  test("starts counting again on a new day", async () => {
    const storage = memoryStorage();
    assert.equal(await consumeDailyQuota(storage, "2026-09-24", 1), "ok");
    assert.equal(await consumeDailyQuota(storage, "2026-09-24", 1), "exceeded");
    assert.equal(await consumeDailyQuota(storage, "2026-09-25", 1), "ok");
  });

  test("a late request for the previous day counts toward today instead of resetting it", async () => {
    const storage = memoryStorage();
    assert.equal(await consumeDailyQuota(storage, "2026-09-25", 2), "ok");
    assert.equal(await consumeDailyQuota(storage, "2026-09-24", 2), "ok");
    assert.equal(await consumeDailyQuota(storage, "2026-09-25", 2), "exceeded");
  });

  test("a limit of 0 closes intake", async () => {
    assert.equal(await consumeDailyQuota(memoryStorage(), "2026-09-25", 0), "exceeded");
  });
});

describe("dailyLimit", () => {
  test("reads a whole number (0 closes intake) and falls back to 100 otherwise", () => {
    assert.equal(dailyLimit("20"), 20);
    assert.equal(dailyLimit("0"), 0);
    for (const raw of [undefined, "", "-5", "2.5", "many"]) {
      assert.equal(dailyLimit(raw), 100, String(raw));
    }
  });
});

describe("DailyQuota", () => {
  test("answers with the result for the requested day", async () => {
    const quota = new DailyQuota({ storage: memoryStorage() }, { DAILY_ISSUE_LIMIT: "1" });
    const first = await quota.fetch(consumeRequest("2026-09-24"));
    assert.equal(first.status, 200);
    assert.deepEqual(await first.json(), { result: "ok" });
    assert.deepEqual(await (await quota.fetch(consumeRequest("2026-09-24"))).json(), { result: "exceeded" });
  });

  test("uses 100 when no limit is configured", async () => {
    const quota = new DailyQuota({ storage: memoryStorage() }, {});
    for (let index = 0; index < 100; index += 1) {
      assert.deepEqual(await (await quota.fetch(consumeRequest("2026-09-24"))).json(), { result: "ok" });
    }
    assert.deepEqual(await (await quota.fetch(consumeRequest("2026-09-24"))).json(), { result: "exceeded" });
  });

  test("refuses a malformed day with 400", async () => {
    const quota = new DailyQuota({ storage: memoryStorage() }, {});
    for (const day of [undefined, "2026-9-24", "today", 20260924]) {
      assert.equal((await quota.fetch(consumeRequest(day))).status, 400, String(day));
    }
    const notJSON = new Request("https://daily-quota/consume", { method: "POST", body: "day" });
    assert.equal((await quota.fetch(notJSON)).status, 400);
  });
});
