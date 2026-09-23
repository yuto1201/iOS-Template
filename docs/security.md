# Security and secret management

## 1. 分類

### Repositoryへ置いてよいもの

- Bundle ID、App ID、公開URL
- Supabase Project URL
- Supabase Publishable Key
- 変数名だけの `.env.example`
- 秘密を含まない `Config/Public.xcconfig`
- マイグレーション、RLS Policy、合成seed

Publishable Keyは公開クライアント用ですが、テンプレートでは設定の混同を避けるため、初期値を生成済みローカル設定へ入れる方式を優先します。

### Repositoryへ置いてはいけないもの

- Supabase Secret Key、旧 `service_role`
- App Store Connect API private keyの内容
- Cloudflare API Token
- ElevenLabs API Key
- GitHub Token
- 証明書の秘密鍵、Provisioning profileの秘密情報
- 本番ユーザー情報、未加工の分析データ
- Cookie、Session、認証済みブラウザStorage

## 2. 保存先

秘密はmacOS Keychainのgeneric passwordを基本とします。Service名は次の形式です。

```text
ios-template/${appSlug}/${service}/${environment}/${keyName}
```

例:

```text
ios-template/template-app/app-store-connect/production/key-id
ios-template/template-app/cloudflare/production/api-token
ios-template/template-app/elevenlabs/production/api-key
```

ファイル形式が必須の場合だけ、次へ保存します。

```text
~/Library/Application Support/iOS-Template/secrets/${appSlug}/
```

- ディレクトリ権限: `0700`
- ファイル権限: `0600`
- リポジトリからのシンボリックリンク: 禁止
- バックアップや共有の扱い: ユーザーの個人用秘密として管理

## 3. 実行時の取扱い

- CodexまたはClaudeが認証済み外部コマンドを起動する直前にだけ秘密を取得する。
- Global shell profileや永続的な環境変数へ書かない。
- 秘密をコマンドライン引数へ直接置かない。
- 標準出力・標準エラーをredactする。
- 一時ファイルは `mktemp -d` で作り、終了trapで削除する。
- 秘密を含む一時ファイルへ `0600` を設定する。
- 結果にはアカウント名、対象、成功可否、外部参照IDだけを残す。
- 環境変数は子processを`exec`する直前にshellからexportし、秘密値を`env NAME=value`のargvへ置かない。

## 4. iOS設定

- `Config/Public.xcconfig`: 秘密ではない値。Git管理可。
- `Config/Local.xcconfig`: ローカル生成。Git管理外。
- `Config/Local.xcconfig.example`: Key名と説明だけ。Git管理可。
- `Config/ownership.yml`: 期待する個人アカウントとアプリ固有の公開identifier。Git管理可。
- iOSアプリにSecret Keyを入れない。
- 管理権限が必要な操作はサーバー側または認可済み実行モデルの運用処理で行う。

アプリBundle内の値は、難読化しても秘密にはなりません。Keychainは端末上のユーザー資格情報には使えますが、配布アプリへサービス管理鍵を隠す方法としては使いません。

## 5. Supabase

- Schema source of truth: `supabase/migrations/*.sql`
- RLS: 公開スキーマで必須
- Client: Project URLとPublishable Key
- Backend／認可済み実行モデルのみ: Secret Keyまたは管理権限
- `supabase/config.toml`: `env()` 参照を使い、秘密値を直書きしない
- `supabase/seed.sql`: 合成データだけ
- `.temp/`、`.branches/`: Git管理外
- 本番 `db reset --linked`: 禁止

CodexとClaudeはmigrationファイルの作成、ローカルDB検証、認証済みremote操作を実行できます。remote操作はIssue contractと`Config/ownership.yml`のOrganization ID／Project Refを照合し、Project Ref未設定中は実行しません。

## 6. 共通ガードの対象

- `security find-generic-password` などのKeychain読取
- 専用秘密ディレクトリの読取
- GitHub、Supabase、Cloudflare、Linear、Vercel、ElevenLabs、App Store Connect CLI（固定版`asc`を含む）／MCP／plugin
- 認証済みremote Git
- 外部MCP・プラグイン
- `.env`、private key、Tokenを表示するコマンド

CodexとClaudeのどちらも、秘密値を読み取って表示する操作、永続環境へexportする操作、リポジトリへ保存する操作を行いません。秘密取得自体は許可しますが、`run-with-secret.sh`または`run-with-private-key.sh`を使い、認可済み子processへだけ渡します。シンボリックリンクは解決後の物理パスで再検査します。

アカウント分離は端末ごとのprovider sessionと`Config/ownership.yml`のpreflightで行います。同一OSユーザー上の暗号学的分離ではありません。

App Store Connectのmulti-line `.p8` private keyはKeychainの1行secret interfaceへ入れません。リポジトリ外の専用ディレクトリへ`0600`で保存し、認可済み実行モデルが必要な子processへ渡す間だけ使用します。Key IDとIssuer IDはKeychainまたは公開ownership設定へ分けます。

[固定版`asc` adapter](../specs/architecture.md#72-app-store-connect-api-adapter)では、Team keyのApp Manager roleだけを使います。Key IDとIssuer IDは`ios-template/${appSlug}/app-store-connect/production/`配下のKeychain generic passwordから、`.p8`は上記の専用ディレクトリから、guarded runnerが起動する子processのenvへだけ渡します。`asc auth login`、`asc`自身のKeychain保存、`~/.asc/`やrepository内`.asc/`のconfig、web session、Apple IDのpassword／2FAは使いません。runnerはtelemetryを無効化し、stdout／stderrをredactし、Key ID、Issuer ID、private keyとその値hashをartifact、Issue、PR、log、promptへ残しません。

### 固定版ascの利用

`tools/install-asc-cli.sh`は`Config/asc-cli.json`の固定releaseをHTTPSで取得し、checksum fileとbinaryのSHA-256を照合して、repository外の`~/Library/Application Support/iOS-Template/tools/asc/<version>/asc`へ排他的に配置します。同じbytesは再利用し、異なる既存fileやsymlinkを上書きしません。更新は別Issueでpinを変更します。

Identity bootstrap済みのアプリでは、Team keyのApp Manager roleを使い、Keychainの上記命名に従う`app-store-connect/production/key-id`と`issuer-id`、アプリの専用秘密ディレクトリ直下の`app-store-connect-production.p8`を準備します。runnerは`Config/app-identity.json`の`appSlug`から固定pathを計算し、既存secret wrapperを実HOMEで連鎖させます。任意の秘密pathや資格情報をCLI flagで渡しません。最内側のhelperだけが空の一時HOMEとcwd、固定PATH、telemetry無効、Keychain bypass、存在しないconfig path、JSON出力、Team key設定を構成し、秘密を子process envへ渡します。起動ごとのversion／digest照合、120秒の上限、両出力のredactionを強制します。

使用例は`tools/asc-run.sh --operation appstore.inspect_app -- apps list --bundle-id com.example.app`です。現在のallowlistは`apps list`、`apps info view --app <id>`、`versions list --app <id>`、`bundle-ids list`の読取subsetだけです。`--output json`はrunnerが強制し、その他のcommand／flag、web、auth、signing、workflow実行、telemetry設定は拒否します。live実行には引き続きrelease／full／strict、宣言済みoperation／Executor、account／target確認と必要な承認が必要です。この基盤だけではproduction preflightやlive操作を承認しません。

`tools/tests/test-asc-cli.sh`はfake binaryと一時HOMEだけを使い、network／実Keychainを利用しません。`IOS_TEMPLATE_TEST_MODE=1`時だけpin、install root、release directory、security executableとtimeoutのtest overrideを許可し、pathは絶対・非symlinkを要求します。本番modeではtest overrideの存在を拒否します。

## 7. 漏えい時

1. 進行中の外部操作を止める。
2. 対象の秘密を失効・rotateする。
3. Git履歴、Issue、PR、ログ、Artifactへの混入範囲を確認する。
4. 公開済みの場合は、削除だけで済ませず失効を確認する。
5. 原因と再発防止をSecurity Regression Issueへ記録する。秘密値そのものは記録しない。
