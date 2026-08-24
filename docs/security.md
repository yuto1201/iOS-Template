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

- Codexの外部コマンドを起動する直前にだけ秘密を取得する。
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
- 管理権限が必要な操作はサーバー側またはCodexの運用処理で行う。

アプリBundle内の値は、難読化しても秘密にはなりません。Keychainは端末上のユーザー資格情報には使えますが、配布アプリへサービス管理鍵を隠す方法としては使いません。

## 5. Supabase

- Schema source of truth: `supabase/migrations/*.sql`
- RLS: 公開スキーマで必須
- Client: Project URLとPublishable Key
- Backend/Codex only: Secret Keyまたは管理権限
- `supabase/config.toml`: `env()` 参照を使い、秘密値を直書きしない
- `supabase/seed.sql`: 合成データだけ
- `.temp/`、`.branches/`: Git管理外
- 本番 `db reset --linked`: 禁止

Claudeはmigrationファイルを作成し、ローカルDBで検証できます。`supabase link`、`db pull`、`db push`、remote advisor、remote SQLはCodexへ委託します。

## 6. Claudeガードの対象

- `security find-generic-password` などのKeychain読取
- 専用秘密ディレクトリの読取
- GitHub、Supabase、Cloudflare、ElevenLabs、App Store Connect CLI
- 認証済みremote Git
- 外部MCP・プラグイン
- `.env`、private key、Tokenを表示するコマンド

Read、Glob、Grep、Computer Useを含む非shell Toolでも、専用秘密ディレクトリ、Keychain、`.env`、credential・Token・private-key形式のパスは拒否します。シンボリックリンクは解決後の物理パスで再検査します。Bashではprovider CLIやremote Gitを絶対パス、interpreter、wrapper、または管理対象helper経由で呼び出しても同じく拒否します。

Hookは誤操作の防止策で、同一OSユーザー上の暗号学的な分離ではありません。

App Store Connectのmulti-line `.p8` private keyはKeychainの1行secret interfaceへ入れません。リポジトリ外の専用ディレクトリへ`0600`で保存し、Codexが必要な子processへ渡す間だけ使用します。Key IDとIssuer IDはKeychainまたは公開ownership設定へ分けます。

## 7. 漏えい時

1. 進行中の外部操作を止める。
2. 対象の秘密を失効・rotateする。
3. Git履歴、Issue、PR、ログ、Artifactへの混入範囲を確認する。
4. 公開済みの場合は、削除だけで済ませず失効を確認する。
5. 原因と再発防止をSecurity Regression Issueへ記録する。秘密値そのものは記録しない。
