import type { FeedbackCategory, FeedbackSubmission } from "./feedback.ts";

export type IssueContent = { title: string; body: string; labels: string[] };

const categoryTitles: Record<FeedbackCategory, string> = { bug: "Bug", request: "Request", other: "Other" };
const titleGraphemes = 40;
// GitHub rejects longer titles; emoji built from many code points can pass it within 40 graphemes.
const maxTitleCharacters = 256;
const segmenter = new Intl.Segmenter("en", { granularity: "grapheme" });

export function issueContent(submission: FeedbackSubmission): IssueContent {
  const prefix = `[${categoryTitles[submission.category]}] `;
  const summary = firstGraphemes(submission.body.replace(/\s+/g, " ").trim(), titleGraphemes,
                                 maxTitleCharacters - [...prefix].length);
  return {
    title: prefix + summary,
    body: [
      "## Feedback",
      "",
      fenced(submission.body),
      "",
      "## Environment",
      "",
      `- Category: ${submission.category}`,
      `- App: ${code(submission.appVersion)} (${code(submission.build)})`,
      `- OS: ${code(submission.osVersion)}`,
      `- Device: ${code(submission.deviceModel)}`,
      `- Locale: ${code(submission.locale)}`,
    ].join("\n"),
    labels: ["feedback", submission.category],
  };
}

/** Wraps text in a code block that the text itself cannot close, so GitHub renders no mentions or links. */
export function fenced(text: string): string {
  const longestRun = Math.max(0, ...Array.from(text.matchAll(/`+/g), (match) => match[0].length));
  const fence = "`".repeat(Math.max(3, longestRun + 1));
  return `${fence}text\n${text}\n${fence}`;
}

/** Inline code, so GitHub renders no links or references. The values cannot contain backticks. */
function code(value: string): string {
  return `\`${value}\``;
}

function firstGraphemes(text: string, limit: number, maxCharacters: number): string {
  let result = "";
  let count = 0;
  let characters = 0;
  for (const { segment } of segmenter.segment(text)) {
    const length = [...segment].length;
    if (count === limit || characters + length > maxCharacters) break;
    result += segment;
    count += 1;
    characters += length;
  }
  return result;
}
