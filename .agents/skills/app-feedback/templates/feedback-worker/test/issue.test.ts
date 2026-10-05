import { describe, test } from "node:test";
import assert from "node:assert/strict";
import type { FeedbackSubmission } from "../src/feedback.ts";
import { fenced, issueContent } from "../src/issue.ts";

const submission: FeedbackSubmission = {
  category: "request",
  body: "Please add a widget\nthat shows the next payday.",
  appVersion: "1.1",
  build: "5",
  osVersion: "27.0",
  deviceModel: "iPad16,3",
  locale: "en_US",
};

describe("issueContent", () => {
  test("titles the issue with the category and the first 40 characters on one line", () => {
    const content = issueContent({ ...submission, body: "あ".repeat(30) + "\n" + "い".repeat(30) });
    assert.equal(content.title, "[Request] " + "あ".repeat(30) + " " + "い".repeat(9));
  });

  test("keeps the title within GitHub's 256 characters when emoji are built from many code points", () => {
    const family = "\u{1F468}\u200D\u{1F469}\u200D\u{1F467}\u200D\u{1F466}";
    const title = issueContent({ ...submission, body: family.repeat(40), category: "bug" }).title;
    assert.ok([...title].length <= 256, `${[...title].length} characters`);
    assert.ok(title.startsWith("[Bug] " + family));
    assert.ok(!title.endsWith("\u200D"));
  });

  test("shows device details as code, so GitHub does not turn them into links or references", () => {
    const body = issueContent({ ...submission, deviceModel: "www.example.com", build: "GH-1" }).body;
    assert.ok(body.includes("- Device: `www.example.com`"));
    assert.ok(body.includes("(`GH-1`)"));
  });

  test("keeps a short body whole in the title", () => {
    assert.equal(issueContent({ ...submission, body: "Crash", category: "bug" }).title, "[Bug] Crash");
  });

  test("labels the issue with feedback and the category", () => {
    assert.deepEqual(issueContent(submission).labels, ["feedback", "request"]);
    assert.deepEqual(issueContent({ ...submission, category: "other" }).labels, ["feedback", "other"]);
  });

  test("puts the body in a code block and lists the environment", () => {
    const body = issueContent(submission).body;
    assert.equal(
      body,
      [
        "## Feedback",
        "",
        "```text",
        "Please add a widget",
        "that shows the next payday.",
        "```",
        "",
        "## Environment",
        "",
        "- Category: request",
        "- App: `1.1` (`5`)",
        "- OS: `27.0`",
        "- Device: `iPad16,3`",
        "- Locale: `en_US`",
      ].join("\n"),
    );
  });
});

describe("fenced", () => {
  test("uses a fence longer than any backtick run, so the body cannot close it", () => {
    assert.equal(fenced("see ``` here and `` there"), "````text\nsee ``` here and `` there\n````");
  });

  test("keeps mentions and issue references inside the code block", () => {
    const block = fenced("@octocat see #12");
    assert.ok(block.startsWith("```text\n"));
    assert.ok(block.endsWith("\n```"));
    assert.ok(block.includes("@octocat see #12"));
  });
});
