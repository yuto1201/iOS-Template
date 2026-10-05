import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import * as entry from "../src/index.ts";
import { repositoryName } from "../src/github.ts";

const config = JSON.parse(readFileSync(new URL("../wrangler.jsonc", import.meta.url), "utf8"));

// The template keeps placeholder values in double braces; the provisioning tool writes the app values (D-076).
function appValue(value: unknown, placeholder: string, valid: (value: string) => boolean): void {
  assert.equal(typeof value, "string");
  if (value === `{{${placeholder}}}`) return;
  assert.ok(valid(value as string), `${placeholder} has an invalid value`);
}

test("the Workers config matches the bindings the code uses", () => {
  assert.deepEqual(Object.keys(config).sort(), [
    "compatibility_date", "durable_objects", "main", "migrations", "name", "observability", "ratelimits", "vars",
  ]);
  assert.equal(config.main, "src/index.ts");
  appValue(config.name, "WORKER_NAME", (name) => /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?-feedback$/.test(name));
  assert.equal(config.ratelimits.length, 1);
  const [limit] = config.ratelimits;
  assert.deepEqual({ ...limit, namespace_id: undefined }, {
    name: "FEEDBACK_SENDER_LIMIT", namespace_id: undefined, simple: { limit: 1, period: 60 },
  });
  // Unique per Cloudflare account: apps sharing one would share per-sender counts.
  appValue(limit.namespace_id, "RATE_LIMIT_NAMESPACE_ID", (id) => /^[1-9][0-9]{0,8}$/.test(id));
  assert.deepEqual(config.durable_objects, { bindings: [{ name: "DAILY_QUOTA", class_name: "DailyQuota" }] });
  assert.deepEqual(config.migrations, [{ tag: "v1", new_sqlite_classes: ["DailyQuota"] }]);
  assert.deepEqual(Object.keys(config.vars).sort(), ["DAILY_ISSUE_LIMIT", "GITHUB_REPOSITORY"]);
  assert.equal(config.vars.DAILY_ISSUE_LIMIT, "100");
  appValue(config.vars.GITHUB_REPOSITORY, "GITHUB_REPOSITORY",
    (repository) => repositoryName(repository).endsWith("-feedback"));
  // Invocation logs would keep request details, including the sender address (D-076).
  assert.deepEqual(config.observability, { enabled: true, logs: { invocation_logs: false } });
  assert.equal(typeof entry.DailyQuota, "function");
  assert.equal(typeof entry.default.fetch, "function");
});
