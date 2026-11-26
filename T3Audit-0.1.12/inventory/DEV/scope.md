# DEV 開発ワークスペースとパネル

対象は元の macOS T3 Code 0.1.12。Electron が表示する Web 実装、同梱サーバー、共有コントラクトを `.source` の `ca81b7b97a1c4b91e5ac25768d0f6629f37732fd` で調べた。

`features.tsv` の 355 行に操作または状態遷移、ソース根拠、再生に必要な条件、確認する結果を記録した。比較に使う行では、操作前後の Git ref、worktree パス、ファイル内容、スレッド ID、またはホスト上の状態で差を判定する。`entries.tsv` の 737 行は起点、メニュー項目、動作 ID、選択肢、キー、MCP ツールなどを機能 ID に結び付ける。同じ機能を開く複数の起点も記録した。

## 調査した実装

| 対象 | 起点と実装 | 確認した静的レジストリ |
| --- | --- | --- |
| プロジェクトと worktree | `CommandPalette.tsx`、`BranchToolbar*.tsx`、`WorktreeRepositoriesControl.tsx`、`useComposerSend.ts`、`WorktreeSetupCard.tsx`、`ThreadLaunchService.ts`、`WorktreeSetupTracker.ts`、`TaskFolders.ts`、`restoreMissingWorktree.ts`、`ProviderRuntimeRecoveryService.ts` | Workspace 選択、準備ステージと状態、branch 命名、submodule 方針、worktree 清掃のモードと保持条件、worktree MCP |
| Git と差分 | `BranchToolbarBranchSelector.tsx`、`ThreadRepositorySections.tsx`、`GitActionsControl*.ts*`、`DiffPanel.tsx`、`components/diffs/`、`GitManager.ts`、`storageCleanup.ts`、`CheckpointRollbackService.ts` | Git action ID、ref バッジ、差分 scope と比較先、差分表示、ファイルを保持する巻戻しと復元 |
| PR、CI、レビュー | `components/pullRequest/`、`hooks/usePullRequestLinking.ts`、`mcp/toolkits/pullRequests/`、`PullRequestReviewGuideService.ts`、`GitHubPullRequestProvider.ts`、`GitHubPullRequestApi.ts` | PR 一覧の絞り込みと並べ替え、詳細・リンク・stack メニュー、merge 方法、レビュー判定、CI、PR MCP |
| ファイルとエディター | `components/files/`、`fileContextMenu.ts`、`diffFileActions.ts`、`OpenInPicker.tsx`、`WorkspaceFileSystem.ts`、`packages/contracts/src/editor.ts` | ローカル検出または remote link の editor ID と表示名、ファイルツリーのコンテキスト操作、ファイル形式ごとの表示 |
| ブラウザーと右パネル | `RightPanelTabs.tsx`、`useRightPanelActions.ts`、`useRightPanelSurfaceClose.ts`、`components/preview/`、`browser/`、`DesktopWindow.ts`、`apps/desktop/src/preview/`、`apps/server/src/preview/`、`IntegrationsSettings.tsx` | 追加項目とタブのコンテキスト操作、ブラウザーの操作・外観・viewport プリセット、ネイティブ WebContents のコンテキスト操作、preview と HTML の MCP |
| 端末とアクション | `ThreadTerminalDrawer.tsx`、`useThreadTerminalActions.ts`、`useChatTerminalActions.ts`、`ProjectScriptsControl.tsx`、`projectScriptEditor.tsx`、`ThreadServersPanel.tsx`、`terminal/Manager.ts`、`ProjectSetupScriptRunner.ts`、`ThreadSettlementService.ts` | 端末コンテキスト操作、タブ・分割・フォーカスのキー、アクション作成と実行、開発サーバーの検出・転送・停止 |
| 仮想端末 | `components/device/`、`settings/*DeviceHostEditor.tsx`、`apps/server/src/device/`、`mcp/toolkits/device/` | 端末のセットアップ、表示、操作、Tools の選択肢、端末 MCP |

実装の起点を表示ラベル、ハンドラーまたは状態 ID で検索し、操作を決定する条件と結果までたどった。手で照合した別経路と UI 表記を `menu-entries.txt` に置いた。`verify_inventory.py` は決まった範囲の型、キー、選択肢、MCP 定義から行番号付きで項目を抽出する。worktree、preview、previewControls、pullRequests、device の各ツール定義では、マッピングが静的 `Tool.make` 名をすべて含むことを確認する。機能の見出しと再生条件は手作業で記述した。

## 再検証

リポジトリ側のソースを変更せずに検証できる。

```sh
cd T3Audit-0.1.12/inventory/DEV
python3 verify_inventory.py
```

生成部分を更新する場合は `python3 verify_inventory.py --refresh-entries` を実行する。先頭の機能ごとの entry は保持する。通常の検証では pin、TSV のヘッダーと列数、連番、機能参照、ソース位置の範囲、静的抽出結果との一致を確認する。ラベルの翻訳や操作の実機結果はこの検証の対象外。

## 実機確認の条件

- Worktree の `preparing`、同期 setup 失敗、準備済み checkout の Retry、再起動中断、provider 開始直前の保留、worktree 欠落からの再作成を別の条件で再生する。再起動の `starting` と `preparing` は分ける。清掃はスレッド共有、候補パスのリース、ローカル変更、保持設定、経過時間、remote のマージ判定で結果が変わる。
- PR の閲覧、編集、レビュー、CI、stack 操作はホストの capability と権限に依存する。GitHub の CI 実装にはソース根拠がある。全ホストの操作組み合わせは実機で確認する。PR、repo、環境、タグ、アカウント、check、検索結果は実行時の候補。
- ファイルパスから外部エディターを起動できるかは、インストール検出、ローカル実行権限、remote 対応エディター、SSH の到達先で変わる。ローカルアプリとデスクトップ guest のネイティブコンテキスト項目は動的に変わる。
- ブラウザーはローカル Electron guest とサーバー側ブラウザーで条件が異なる。ナビゲーション、録画、注釈、DevTools、PiP、転送、Cookie のインポート実行可否を型やラベルだけで同一視しない。Cookie の確認には専用テストプロファイルを使う。
- 仮想端末に出る操作は iOS、Android、利用可能なホストと機種、端末コントロールの能力、接続状況で変わる。端末 ID、OS バージョン、ホスト名、稼働中セッションは実行時の候補。shell の選択はサーバー起動環境の `T3CODE_TERMINAL_SHELL` で指定する。
- 機能に直接つながるデスクトップ文脈と共有 Web 実装を扱った。一般的なアプリメニュー、アカウント管理、OS のインストール手順、別クライアント固有の画面は DEV の範囲外。アプリ、ホスト API、アカウントへの接続による動作確認はこの工程では行っていない。
