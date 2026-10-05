import { describe, test } from "node:test";
import assert from "node:assert/strict";
import { graphemeCount, maxBodyGraphemes, parseSubmission } from "../src/feedback.ts";

const valid = {
  category: "bug",
  body: "  The calendar does not scroll.  ",
  appVersion: "1.1",
  build: "5",
  osVersion: "27.0",
  deviceModel: "iPhone18,1",
  locale: "ja_JP",
};

describe("parseSubmission", () => {
  test("accepts a valid submission and trims the body", () => {
    const result = parseSubmission(valid);
    assert.deepEqual(result, { ok: true, value: { ...valid, body: "The calendar does not scroll." } });
  });

  test("accepts every category", () => {
    for (const category of ["bug", "request", "other"]) {
      assert.equal(parseSubmission({ ...valid, category }).ok, true, category);
    }
  });

  test("rejects values that are not a plain object", () => {
    for (const value of [null, "text", 3, [valid]]) {
      assert.equal(parseSubmission(value).ok, false, JSON.stringify(value));
    }
  });

  test("rejects unknown fields, so no other data can be sent", () => {
    assert.equal(parseSubmission({ ...valid, balance: 120000 }).ok, false);
  });

  test("rejects a missing or unknown category", () => {
    const { category: _omitted, ...withoutCategory } = valid;
    assert.equal(parseSubmission(withoutCategory).ok, false);
    assert.equal(parseSubmission({ ...valid, category: "praise" }).ok, false);
  });

  test("rejects an empty or whitespace-only body", () => {
    assert.equal(parseSubmission({ ...valid, body: "" }).ok, false);
    assert.equal(parseSubmission({ ...valid, body: " \n\t " }).ok, false);
    assert.equal(parseSubmission({ ...valid, body: 12 }).ok, false);
  });

  test("counts the body limit in grapheme clusters, like iOS String.count", () => {
    const family = "👨‍👩‍👧";
    assert.equal(graphemeCount(family), 1);
    assert.equal(parseSubmission({ ...valid, body: family.repeat(maxBodyGraphemes) }).ok, true);
    assert.equal(parseSubmission({ ...valid, body: "あ".repeat(maxBodyGraphemes + 1) }).ok, false);
  });

  test("rejects metadata with characters outside the allowed set or longer than 64", () => {
    assert.equal(parseSubmission({ ...valid, deviceModel: "@octocat" }).ok, false);
    assert.equal(parseSubmission({ ...valid, osVersion: "27.0\n## Title" }).ok, false);
    assert.equal(parseSubmission({ ...valid, locale: "" }).ok, false);
    assert.equal(parseSubmission({ ...valid, appVersion: "1".repeat(65) }).ok, false);
    assert.equal(parseSubmission({ ...valid, build: 5 }).ok, false);
  });
});
