# [Legal pages]: PayCycle privacy, terms, and support

Target repository: `yuto1201/Web-AppLibrary`
Source: `yuto1201/iOS-PayCycle#54` at `aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`
Handoff ID: `pay-cycle-v1`

## Goal

Publish the confirmed support, privacy, and terms pages for PayCycle at the fixed URLs below. Each page shows its Japanese and English text on the same page with an in-page language switch; do not create a separate URL per language. Use 1 Issue = 1 Branch = 1 PR and preserve the source text.

## Confirmed app facts

- App slug: `pay-cycle`
- Bundle ID: `com.yuto1201.paycycle`
- Platforms: iOS, iPadOS
- Feature: Shows the next scheduled payday.
- Data use: No personal data is collected.
- Advertising: not-used — No advertising SDK is included.
- Purchases: not-used — No in-app purchase is included.

## User-controlled handoff and approval

The user forwards this prompt to the Web implementation agent and retains final approval of legal text and publication. AI review, this Issue, and a deployment do not grant that approval. Do not publish until the user's approval references are recorded.

## Pages and exact source text

### support

- URL: `https://app.yutodev.com/apps/pay-cycle/support/`
- Languages on this page: en-US, ja

#### support / en-US

- Source: `App Store/legal/en-US/support.md`
- Source digest: `sha256:7e97c4f4d752a0c11bf1c8712cfe3b5952a1540d7d53af178063ff3c8bb99f84`
- Source approval: https://github.com/yuto1201/iOS-PayCycle/issues/54#issuecomment-1

```markdown
# Support

Status: Confirmed

Contact the PayCycle support team from the approved support channel.
```

#### support / ja

- Source: `App Store/legal/ja/support.md`
- Source digest: `sha256:a0eae34cfe4d500dca7b755871eb54c91f224054ff0cc3a960c782d341292aa2`
- Source approval: https://github.com/yuto1201/iOS-PayCycle/issues/54#issuecomment-1

```markdown
# サポート

Status: Confirmed

承認済みのサポート窓口からPayCycleのサポートチームへ連絡できます。
```

### privacy

- URL: `https://app.yutodev.com/apps/pay-cycle/privacy/`
- Languages on this page: en-US, ja

#### privacy / en-US

- Source: `App Store/legal/en-US/privacy.md`
- Source digest: `sha256:a9a1e0bb7c4d0f0423003287518bc16da0a47b8c4da0f9ab4cb6e6b6a5e4c012`
- Source approval: https://github.com/yuto1201/iOS-PayCycle/issues/54#issuecomment-1

```markdown
# Privacy Policy

Status: Confirmed

PayCycle does not collect personal data in this approved fixture.
```

#### privacy / ja

- Source: `App Store/legal/ja/privacy.md`
- Source digest: `sha256:53cf0a4935c554eff230c6d5ad262dcd2b18d301a3c66d4e025715be02413d6c`
- Source approval: https://github.com/yuto1201/iOS-PayCycle/issues/54#issuecomment-1

```markdown
# プライバシーポリシー

Status: Confirmed

この承認済みフィクスチャではPayCycleは個人データを収集しません。
```

### terms

- URL: `https://app.yutodev.com/apps/pay-cycle/terms/`
- Languages on this page: en-US, ja

#### terms / en-US

- Source: `App Store/legal/en-US/terms.md`
- Source digest: `sha256:416b5e3f59ef3f9f3877095df994d9800bfd3a317d3bd0c041b6f1e6f79859c4`
- Source approval: https://github.com/yuto1201/iOS-PayCycle/issues/54#issuecomment-1

```markdown
# Terms of Use

Status: Confirmed

Use PayCycle lawfully and verify each scheduled payday before relying on it.
```

#### terms / ja

- Source: `App Store/legal/ja/terms.md`
- Source digest: `sha256:cf95dce6ad9c440beea04efc87e3e74276d1262a0e88a710beaa81e76c31088f`
- Source approval: https://github.com/yuto1201/iOS-PayCycle/issues/54#issuecomment-1

```markdown
# 利用規約

Status: Confirmed

PayCycleを適法に利用し、予定給料日を利用前に確認してください。
```

## Acceptance checks

- Every URL returns HTTP 200 without authentication or an account, at exactly the URL above with no redirect.
- Each page contains both its approved Japanese and English source text, with a language switch on the same page.
- Each of the support, privacy, and terms pages links to the other two pages.
- Read the created Issue back from exactly `yuto1201/Web-AppLibrary` before implementation starts.

## Expected return contract

Return the deployment reference, the three exact public URLs with the source digests of both languages for each page, the Web-AppLibrary Issue URL, and the user's prompt-forward/publication approval references. Do not return credentials or authenticated transcripts.
