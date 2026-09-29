# 派生アプリへのasc経路の取り込み

この文書は、派生アプリ（例: iOS-PayCycle）が、テンプレートのApp Store Connect API経路を取り込む手順です。対象は次の経路です。

- 固定版`asc`と、guarded runner
- operation modelとpreflight
- metadata save
- build upload
- TestFlight配信
- release section

App Privacyと審査用の連絡先情報は、この経路でもブラウザのsectionのまま残ります（D-060）。

## 前提

- 派生アプリはこのテンプレートから作成済みで、Identity bootstrapが完了し、`Config/app-identity.json`に`appSlug`がある。
- Issue、検証、review、mergeの共通workflow toolが、取り込み元のテンプレートと互換である。古い場合は、先にそれらを揃える。
- 取り込みは派生アプリのIssueとして行う。テンプレートから自動で同期するtoolはない。

## 取り込むpath

テンプレートの同じpathから、そのまま取り込みます。`tools/tests/test-appstore-skills.sh`が、この一覧の各pathがテンプレートに実在することを検査します。

### tool

- `tools/install-asc-cli.sh`
- `tools/asc-run.sh`
- `tools/export-appstore-build.sh`
- `tools/distribute-testflight-build.sh`
- `tools/prepare-appstore-sources.sh`
- `tools/prepare-appstore-legal-handoff.sh`
- `tools/capture-appstore-screenshots.sh`
- `tools/build-appstore-screenshot-set.sh`
- `tools/validate-appstore-package.sh`
- `tools/provider-preflight.sh`
- `tools/secret-store.sh`
- `tools/run-with-secret.sh`
- `tools/run-with-private-key.sh`

### helper

- `tools/lib/asc-cli.rb`
- `tools/lib/asc-testflight.rb`
- `tools/lib/appstore-account-evidence.rb`
- `tools/lib/appstore-asset-evidence.rb`
- `tools/lib/appstore-build.rb`
- `tools/lib/appstore-code-inventory.rb`
- `tools/lib/appstore-confirmation.rb`
- `tools/lib/appstore-legal-handoff.rb`
- `tools/lib/appstore-metadata-save.rb`
- `tools/lib/appstore-preparation.rb`
- `tools/lib/appstore-public-evidence.rb`
- `tools/lib/appstore-readback-evidence.rb`
- `tools/lib/appstore-registration-preparation.rb`
- `tools/lib/appstore-release-sections.rb`
- `tools/lib/appstore-source-schema.rb`
- `tools/lib/appstore-xcode-facts.rb`
- `tools/lib/ownership.rb`
- `tools/lib/bounded-command.rb`

### Config

- `Config/asc-cli.json`
- `Config/ownership.yml`

### skill

- `.agents/skills/prepare-appstore-assets/SKILL.md`
- `.agents/skills/save-appstore-metadata/SKILL.md`
- `.agents/skills/submit-appstore-release/SKILL.md`
- `.agents/skills/external-ops/SKILL.md`
- `.claude/skills/prepare-appstore-assets`
- `.claude/skills/save-appstore-metadata`
- `.claude/skills/submit-appstore-release`
- `.claude/skills/external-ops`

`.agents/skills/`は各skillのdirectory全体を取り込みます。`.claude/skills/`は同名directoryへのsymlinkです。

### 文書

- `docs/security.md`
- `docs/agent-contracts/appstore-submission.md`
- `docs/agent-contracts/testflight-distribution.md`

### test

- `tools/tests/test-asc-cli.sh`
- `tools/tests/test-asc-testflight.sh`
- `tools/tests/test-appstore-build.sh`
- `tools/tests/test-appstore-legal-handoff.sh`
- `tools/tests/test-appstore-metadata-save.sh`
- `tools/tests/test-appstore-package.sh`
- `tools/tests/test-appstore-preparation.sh`
- `tools/tests/test-appstore-preparation-migration.sh`
- `tools/tests/test-appstore-release-sections.sh`
- `tools/tests/test-appstore-screenshots.sh`
- `tools/tests/test-appstore-skills.sh`
- `tools/tests/test-provider-ownership.sh`
- `tools/tests/test-provider-preflight.sh`
- `tools/tests/test-secret-store.sh`
- `tools/tests/fixtures/asc`
- `tools/tests/fixtures/appstore/requirements.json`
- `tools/tests/fixtures/providers`

testは`Config/repository-tests.json`の同じdomainへ登録します。testは、fake `asc`、fake `xcodebuild`、一時HOMEだけを使います。

## guard

外部操作はguard付きの経路を通します。

- **guarded runner:** `tools/asc-run.sh`だけが`asc`を起動します。operationごとのsubcommand／flag allowlistと、出力のredactionを強制します。許可されるsubcommandは`docs/security.md`「固定版ascの利用」に一覧があります。
- **secret wrapper:** `tools/run-with-secret.sh`と`tools/run-with-private-key.sh`が、秘密を子process envへだけ渡します。
- **account／targetの確認:** `tools/provider-preflight.sh ... app-store --version <version> --operation appstore.<operation>`が、操作ごとに`Config/ownership.yml`と照合します。

## ownershipの設定

派生アプリの`Config/ownership.yml`の`appStore`へ、そのアプリのTeam IDとBundle IDを書きます。どちらも秘密ではありません。未設定（`null`）のままでは、preflightもlive操作も通りません。

## 認証情報

ユーザーが用意するのは、App Store ConnectのTeam API keyで、roleはApp Managerです。team keyを作れるのは、Account HolderとAdminだけです。

認証情報の置き場所と名前は、appSlugごとに次のとおりです。値はこの文書にもrepositoryにも書きません。

- **Key ID:** Keychainのgeneric password。
  - service: `ios-template/<appSlug>/app-store-connect/production/key-id`
  - account: `<appSlug>`
- **Issuer ID:** Keychainのgeneric password。
  - service: `ios-template/<appSlug>/app-store-connect/production/issuer-id`
  - account: `<appSlug>`
- **秘密鍵（`.p8`）:** `~/Library/Application Support/iOS-Template/secrets/<appSlug>/app-store-connect-production.p8`
  - directoryは`0700`、fileは`0600`とする。
  - repositoryからのsymlinkは作らない。

Keychainへの登録は、ユーザーが`tools/secret-store.sh put --app <appSlug> --service app-store-connect --environment production --key key-id`（`issuer-id`も同じ）で行います。値は標準入力から1行で渡し、コマンドの引数には書きません。AIは秘密の値を入力、表示、記録しません。

配布用の証明書とprofileは、別に一度だけ用意が要ります。手順と、Appleの公式文書で確かめられなかった点は、`docs/agent-contracts/appstore-submission.md`「One-time distribution signing setup」を見てください。

## 取り込み後の確認

1. `tools/install-asc-cli.sh`で、`Config/asc-cli.json`の固定版をrepository外へ配置する。
2. 取り込んだtestを実行する。testは、networkも実際のKeychainも使わない。
3. live操作の前に、操作ごとに`tools/provider-preflight.sh`を実行し、accountとtargetの一致を確かめる。
4. live操作は、派生アプリのIssue contractで宣言したoperation、Executor、ユーザー承認があるときだけ行う。提出には、ユーザーの明示の承認が要る。

## 問題を見つけたとき

派生アプリで共通の問題を見つけたら、`report-template-issue` skillでテンプレートへ報告します。派生アプリ側だけで直したままにしません。
