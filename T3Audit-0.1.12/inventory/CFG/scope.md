# CFG 設定インベントリ

対象は T3 Code macOS 0.1.12 のソース `ca81b7b97a1c4b91e5ac25768d0f6629f37732fd`。Electron のアプリメニューとレンダラー、設定を受け取るサーバーをたどった。TSV の `acceptance` は実機で照合するときの手順。表示、権限、認証、外部接続はソースから判定した。

## ページと入口

| ナビの分類 | ページ |
| --- | --- |
| Preferences | General、Appearance、Chat、Diffs & pull requests、Keybindings、Voice、SnapShots |
| Agents | Providers、Threads、Browser、Devices、Scheduled tasks |
| Code | Projects、Source control & issues、Worktrees |
| Connections | Environments、Sharing & access、Secrets |
| More | Maintenance、Labs、About、Archive |
| ページ内リンク | Diagnostics は Maintenance。Open source licenses は About |

macOS の **Settings...** と **⌘,**、サイドバー、コマンドパレットの入口が `/settings` へつながる。既定は General。旧 `/settings/beta`、`/settings/integrations`、`/settings/storage` はハッシュの移設先を先に確認する。Providers の端末タブは接続先から生成される。Projects の内容は選択したプロジェクトとチェックアウトで変わる。参照先は `apps/desktop/src/window/DesktopApplicationMenu.ts:252`、`apps/web/src/routes/_chat.settings.tsx:209`、`apps/web/src/components/settings/settingsSearch.ts:99`、`apps/web/src/components/settings/settingsSearch.ts:141`、`apps/web/src/components/settings/settingsSearch.ts:1560`、`apps/web/src/components/settings/ProviderSettingsPanel.tsx:399`。

## キーと保存先

- `client` はこのアプリの `ClientSettingsSchema`。デスクトップの IPC は `client-settings.json` を扱う。Web のブラウザー保存には `t3code:client-settings:v1` がある。テーマの外観、配色の組み合わせ、Separate fonts、音声と整形の同意はレンダラーの個別キーを使う。音声の送信先変更と同意の更新は `voiceConsent.ts`。参照先は `packages/contracts/src/settings.ts:416`、`apps/desktop/src/app/DesktopEnvironment.ts:201`、`apps/desktop/src/ipc/methods/clientSettings.ts:26`、`apps/web/src/clientPersistenceStorage.ts:5`、`apps/web/src/speech/voiceConsent.ts:14`。
- `desktop` はホストの `desktop-settings.json`。ネットワーク公開、Tailscale Serve、ローカル環境、更新チャネルはここに属する。ファイルの復号では認識できない値のキーだけを除く。Windows の WSL は画面と保存形式にあるため、macOS では条件外として記録した。参照先は `apps/desktop/src/settings/DesktopAppSettings.ts:71` と `apps/desktop/src/settings/DesktopAppSettings.ts:93`。
- `server` は接続先の `ServerSettings` と設定パッチ。起動形態に応じた state directory の `settings.json` に保存する。範囲は URL の `project`、`machine`、`checkout` で選ぶ。全環境と単一環境の既定値は接続先へパッチを送る。プロジェクトで上書きできるキーは `PROJECT_SCOPED_SERVER_SETTING_KEYS`。同じプロジェクトの複数チェックアウトではメンバー単位で書く。継承のためにキーを除く操作と、null を値として保存できる設定がある。Workspace と Submodules のファイル既定はルートの `t3.json`。組み込み値はそれぞれ `local` と `recursive`。参照先は `apps/server/src/config.ts:150`、`apps/web/src/components/settings/scopedSettings.ts:289`、`packages/contracts/src/settings.ts:1194`、`packages/contracts/src/settings.ts:1230`、`packages/contracts/src/t3ProjectFile.ts:159`。
- 共有対象の一部のサーバー設定は全環境の変更経路で共有できる。書き込み対象は接続状態と設定の取得状態に依存する。テキスト生成モデルの共有は送り先のドライバーとモデルの可用性も見る。検索の `scope` は結果から行へ到達するときの範囲を表す。実際の設定先と書き込み可否はパネル側で確認する。参照先は `packages/client-runtime/src/state/sharedSettings.ts:7`、`packages/client-runtime/src/state/sharedSettings.ts:40`、`apps/web/src/components/settings/settingsSearch.ts:1591`、`apps/web/src/components/settings/SettingsScopeSentence.tsx:51`。
- `effects` に抽出した既定値を載せた。定数名はソースの表記。合成された既定値や列挙値は抽出結果の宣言と該当するヘルパーを参照する。Background activity の既定は Balanced。上書きされていないポリシー項目と間隔はベースプロファイルから決まる。参照先は `packages/contracts/src/settings.ts:1119` と `packages/shared/src/backgroundActivitySettings.ts:24`。

## Labs、起動フラグ、表示条件

Labs の Beta セクションは 10 行。Boring sidebar と Two-line folder rows はクライアント設定。Guest links、Linked environments、Workflows、Skipped runs kept、Suggest next prompt、Simlock device hosts、Fast worktree checkout、Agent feedback は環境設定。二行表示は Boring sidebar をオンにすると出る。Skipped runs kept は Workflows がオンの場合に出る。保存数は既定 500、0 から 10000 の整数。Fast worktree checkout と Agent feedback は全選択接続先の capability を確認する。Guest links はクラウド構成、サインイン、管理ポリシーで操作が変わる。参照先は `apps/web/src/components/settings/LabsSettingsPanel.tsx:36` と `packages/contracts/src/settings.ts:1373`。

起動時の `T3CODE_FEATURE_FLAGS` は `secret_providers`、`tanstack_source`、`github_app_client_id`。先頭二つは Boolean で既定 false。GitHub の公開クライアント ID は既定で未設定。値付きと裸の名前をコンマで区切る。認識される値のデコードに失敗すると全て既定値へ戻る。デスクトップは起動時に使ったフラグとログインシェルのキャッシュを照合し、変更時はバックエンドを再起動する。Secrets 管理には環境がフラグに加えて `secretProviderSettings` を公開している必要がある。参照先は `packages/shared/src/FeatureFlags.ts:13`、`apps/desktop/src/app/DesktopApp.ts:178`、`apps/server/src/ws.ts:1973`、`apps/web/src/components/settings/SecretsSettings.tsx:46`。

検索フィルターと表示条件の両方を参照した。Advanced は通常閉じており、該当アンカーの検索ジャンプで展開する。個別の権限と管理ポリシー、ホストの capability、設定取得済みの接続、プロバイダーやデバイスの検出、macOS の権限、ビルドのクラウド設定が操作可否を決める。Provider の汎用フォームは `providerSettingsForm.hidden` を除外する。ローカル ACP は汎用フォームの Source と Executable を残し、コマンド引数は専用 UI で編集する。cursor の設定スキーマにある `binaryPath` と `apiEndpoint` は汎用フォームで非表示。インスタンス有効化、モデル編集、認証は専用コントロールを経由する。参照先は `apps/web/src/components/settings/AdvancedSettings.tsx:19`、`apps/web/src/components/settings/settingsSearch.ts:1676`、`apps/web/src/components/settings/settingsSearch.ts:1701`、`apps/web/src/components/settings/ProviderSettingsForm.tsx:262`、`apps/web/src/components/settings/ProviderSettingsForm.tsx:375`。

## 再抽出と照合

`T3Audit-0.1.12` から実行する。Python 3.9 以上と Git を使う。依存パッケージとネットワーク接続は不要。

```sh
git -C .source rev-parse HEAD
python3 -B inventory/CFG/extract.py
python3 -B inventory/CFG/build_inventory.py
python3 -B inventory/CFG/extract.py --check
```

`extract.py` は固定リビジョンからルート、静的検索レジストリ、レンダーアンカー候補、スキーマ宣言、プロバイダーフォームのフィールド、セクション候補、起動フラグを行番号付きで出す。セクション候補にはコンポーネントや動的タイトルが含まれる。スキーマ宣言内の型、値、注釈を表示する。空欄の簡易既定値は宣言から確認する。`build_inventory.py` は手で照合した `workflows.txt` と `controls.txt` をソースのレジストリと組み合わせて TSV を更新する。`--check` はヘッダー、ID と参照整合性、行番号の範囲、全静的ルート、全静的検索 ID、Labs の対応行、フォームのフィールドと起動フラグを確認する。操作の意味と一部のゲートは参照先を読んで照合した。

動的データの実値は各環境から取得する。登録済みプロジェクト、環境、カスタムモデル、ACP Registry の配布、ドライバーが報告する認証と機能、モデルの割り当て、クラウドと許可リスト、タスクとログの内容がこれに該当する。静的キー割り当てはコマンド ID を保持し、プロジェクトスクリプトは `script.<id>.run` のパターンを記録した。クライアントとサーバーにはスキーマのみのキーや互換読み取りが残る。例は `voiceMicrophone`、`hiddenThreadTags`、`hideTaggedThreads`、`previousWorktreesDirectories`。アプリ全体の利用量ダイアログや他の作業画面は Settings のルート集計から外す。実機の OS 権限、サーバーの実データ、外部ログイン、リリース配布物での有効化は再生時の確認項目。
