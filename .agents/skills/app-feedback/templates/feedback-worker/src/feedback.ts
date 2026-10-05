export const categories = ["bug", "request", "other"] as const;
export type FeedbackCategory = (typeof categories)[number];

export type FeedbackSubmission = {
  category: FeedbackCategory;
  body: string;
  appVersion: string;
  build: string;
  osVersion: string;
  deviceModel: string;
  locale: string;
};

export type ParseResult = { ok: true; value: FeedbackSubmission } | { ok: false; reason: string };

export const maxBodyGraphemes = 2000;

const metadataFields = ["appVersion", "build", "osVersion", "deviceModel", "locale"] as const;
const allowedFields = new Set<string>(["category", "body", ...metadataFields]);
// Letters, digits, and the punctuation that version strings, model identifiers,
// and locale identifiers use. Nothing here can form Markdown or a mention.
const metadataPattern = /^[A-Za-z0-9 ._,()+-]{1,64}$/;
const segmenter = new Intl.Segmenter("en", { granularity: "grapheme" });

/** Counts user-perceived characters, matching Swift's `String.count`. */
export function graphemeCount(text: string): number {
  let count = 0;
  for (const _ of segmenter.segment(text)) count += 1;
  return count;
}

export function parseSubmission(value: unknown): ParseResult {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return { ok: false, reason: "not an object" };
  }
  const record = value as Record<string, unknown>;
  if (Object.keys(record).some((field) => !allowedFields.has(field))) {
    return { ok: false, reason: "unknown field" };
  }
  const category = record.category;
  if (typeof category !== "string" || !(categories as readonly string[]).includes(category)) {
    return { ok: false, reason: "category" };
  }
  if (typeof record.body !== "string") return { ok: false, reason: "body" };
  const body = record.body.trim();
  if (body.length === 0 || graphemeCount(body) > maxBodyGraphemes) return { ok: false, reason: "body" };
  const metadata: Record<string, string> = {};
  for (const field of metadataFields) {
    const fieldValue = record[field];
    if (typeof fieldValue !== "string" || !metadataPattern.test(fieldValue)) return { ok: false, reason: field };
    metadata[field] = fieldValue;
  }
  return {
    ok: true,
    value: {
      category: category as FeedbackCategory,
      body,
      appVersion: metadata.appVersion,
      build: metadata.build,
      osVersion: metadata.osVersion,
      deviceModel: metadata.deviceModel,
      locale: metadata.locale,
    },
  };
}
