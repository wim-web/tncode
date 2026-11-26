# HOST ソース調査の範囲

対象は T3 Code v0.1.12 の `ca81b7b97a1c4b91e5ac25768d0f6629f37732fd`。macOS デスクトップが起点の操作と、そこから到達するホストサービスを調べた。各行の acceptance は今後のリプレイで判定する条件。実アカウント、実通信、GUI、Swift、稼働中の T3 データにはアクセスしていない。

## 読んだ実装

- プロバイダーは `apps/server/src/provider/builtInDrivers.ts`、`packages/client-runtime/src/providerClients.ts`、各 `provider-*/src/{client,settings,server}` とサーバーの `provider/Drivers` を照合した。設定画面の追加・削除・更新・認証入口から個別ドライバーの設定、status probe、認証・インストール RPC を追った。Pi はモデル検査による認証判定、既定モデルだけ使えない場合の診断、CLI 側での認証、起動引数と信頼設定を別々に記録した。
- 環境は `apps/web/src/components/settings` の Connections、Access と実行時の connection catalog、Electron IPC、SSH、Tailscale、Relay、`apps/server/src/auth` と `peer` を読んだ。T3 Connect のアカウント、ホスト登録、端末承認、環境同士のリンク、外部 MCP クライアント認可は別の権限と寿命を持つ。Guest は設定・リンク発行からゲストページ、招待消費、読み取りと保留メッセージ処理まで追った。
- オーケストレーションは MCP toolkit、`OrchestratorMcpService.ts`、`RemoteDelegation.ts`、`scheduledTasks`、`workflows`、関連 CLI と React 画面を照合した。MCP の子タスク、プロバイダー固有の子作業、予定タスク、永続 Workflow は別の操作として参照できる。
- Usage と制限回復は Usage 画面、集計と台帳、使用量 reader の登録、制限取得・外部ソース、回復 worker を辿った。通知は設定、クライアントの状態監視とバッジ IPC を読んだ。音声は設定、宛先同意、録音と Apple Speech IPC、環境・クラウド転写、モデル管理の HTTP handler を照合した。
- 保護対象のサービスはサーバーの `RpcAuthorization.ts`、クライアントの `clientRpcPermissions.ts`、`McpToolAccess.ts` と組織ポリシーを照合した。追加の設定・操作としてシークレット保管先、ソース管理認証、Issue tracker 接続、MCP App、Device hub、ホスト診断と保守を含む。汎用チャット、エディター連携、通常の PR・Issue 操作と UI 全体の網羅は他スライスの担当範囲。

## 抽出・検証

`features.tsv` は手作業で追ったワークフローと分岐の 225 行。同じリプレイ手順を共有する操作には親行と詳細行がある。`entries.tsv` の 760 行には入口と、登録名を保持した RPC、MCP tool、Workflow action、CLI、HTTP、Electron IPC、ドライバー、設定フィールド、使用量 reader、Usage ショートカットコマンドを収録した。UI 文言は features の参照行付近の静的文字列。実際の到達条件は対応する features 行を参照する。

監査フォルダのルートから実行する。

```sh
git -C .source rev-parse HEAD
python3 inventory/HOST/enumerate.py --check
```

`--check` は source の SHA、連番、列、実在する追跡ファイルの行番号、features への外部キー、登録一覧の再抽出結果を照合する。抽出を更新する場合は `--check` を外す。行番号照合でソースが変わっていないこととファイル範囲を検査する。ワークフローの実行結果はライブリプレイの対象。

## プラットフォームとリプレイ条件

- Mac Electron の操作でも対象が別環境なら、CLI、資格情報、プロジェクトと秘密保管先はそのホスト側のもの。SSH、Relay、ペアリンク、直接接続の到達性と対象ホストの権限は別々に判定する。モバイルの通知・Live Activities は Mac で配信を設定し、受信は対応端末で確認する。ゲスト受信側は専用 Web ページ。WSL は Windows 対応の設定で、Mac ホスト上の WSL 選択は出ない。
- Apple Speech のオンデバイス経路には Darwin 25 以降とサポートされる locale が要る。環境側のネイティブ転写は darwin-arm64 と darwin-x64 を含む別の対応表に従う。Mac の iOS Simulator は Xcode が必要。Android 端末は Android SDK に依存し、SSH、Expo EAS、Simlock はそれぞれ別のホストと資格情報に依存する。
- インストール先の配布版、クラウドサービス、組織ポリシー、利用枠、認証 scope、Provider のモデル・コマンド・ACP capability・登録配布情報は動的。静的なドライバー登録数から、ユーザーのインストールやアカウントで実際に選べる候補数は判定できない。
- リプレイには使い捨ての環境・資格情報・スレッド・端末を使う。新規リンク、取り消し、削除、プロセス停止、クレジット消費、外部通信を含む行は隔離した試験対象を必要とする。契約や handler で確認できる API を含めた。特定アカウントや配布物での UI の表示と成功は未観測。
