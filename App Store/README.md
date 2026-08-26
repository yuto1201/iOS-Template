# App Store submission sources

This directory is the versioned, non-secret source for App Store preparation. It is not a ready-to-publish legal package.

- `metadata/`: app identity and English/Japanese product-page copy.
- `privacy/`: declarations derived from actual app behavior and integrated SDKs.
- `legal/`: drafts generated from the privacy declaration; confirm before first publication.
- `review/`: review instructions and Keychain references, never credentials.
- `release-notes/`: localized version notes.
- `screenshots/`: only audited final screenshot sets and their manifests.
- `submission/`: official-requirement cache, checklist, and sanitized resume records.

Validate offline with an explicit requirements snapshot:

```sh
tools/validate-appstore-package.sh \
  --root 'App Store' \
  --project-root "$PWD" \
  --bundle-id com.yuto.TemplateApp \
  --version 1.0 \
  --requirements 'App Store/submission/requirements.json'
```

The template URLs, legal drafts, screenshots, release-auditor decision, and first-publication confirmation must be replaced by a real app-specific release Issue before submission.
