# CHAT ソースインベントリ

対象は macOS 版 T3 Code 0.1.12 のチャット機能。参照リビジョンは `ca81b7b97a1c4b91e5ac25768d0f6629f37732fd`。操作行の根拠は同じリビジョンの Electron、React、クライアントランタイム、関連するサーバー契約に置いた。

- `features.tsv` は 297 操作行。前提、入口、操作、結果、復旧、副作用、再現条件、判定基準を記録した。
- `entries.tsv` は 716 入口・表示行。メニューの親子、直接ボタン、キーバインドのコマンド ID、画面状態、動的ラベルを対応する操作 ID に結び付けた。一つの操作に複数の入口が付く。
- `check.py` は 157 ソースファイルを参照する行ポインタと操作 ID を照合する。静的な 5 レジストリに現れる 58 ラベルも照合する。

## 根拠を取った箇所

| 対象 | 主なファイルとレジストリ |
| --- | --- |
| 初回画面とプロジェクト取込 | `routes/welcome.tsx`、`components/onboarding/WelcomePage.tsx`、`onboarding/useProjectScans.ts` |
| プロジェクトの作成、追加、選択、切替、整理 | `CommandPalette.tsx`、`DraftHeroHeadline.tsx`、`useNewProject.ts`、`AddProjectToMachineDialog.tsx`、`ProjectSettingsPanel.tsx`、`projectGrouping.ts` |
| 通常・scratch・プロンプトリンク下書き | `useHandleNewThread.ts`、`useScratchProject.ts`、`composerDraftStore.ts`、`NewThreadLinkView.tsx` |
| サイドバー、検索、単一・複数選択メニュー | `Sidebar.tsx`、`SidebarThreadRow.tsx`、`threadActionMenu.logic.ts`、`useThreadActionMenu.ts`、`CommandPaletteThreadActions.tsx`、`CommandPaletteThreadItems.tsx` |
| Triage、Snooze、アーカイブ | `useThreadActions.ts`、`useThreadLifecycle.tsx`、`ArchivedThreadsPanel.tsx`、`CustomSnoozeDialog.tsx`、`threadSettled.ts`、`settings.ts` の既定 Snooze プリセット |
| Composer、モデル、作業領域、添付 | `ChatComposer.tsx`、`composerCommandKey.ts`、`useComposerMenuItems.ts`、`ComposerFooterControls.tsx`、`runtimeModeConfig.ts`、`useComposerAttachmentIntake.ts`、`BranchToolbar.tsx` |
| 送信、キュー、停止・再開、分岐 | `ChatView.tsx`、`useComposerSend.ts`、`QueuedRunsControl.tsx`、`useQueuedRunEdit.ts`、`useComposerResume.ts`、`useTimelineRewind.ts`、`useSideChat.ts`、`ThreadRelationshipsControl.tsx` |
| 承認、質問、外部要求 | `ComposerPendingApprovalActions.tsx`、`ComposerPendingUserInputPanel.tsx`、`usePendingThreadRequests.ts`、`SecretRequestCard.tsx`、`LinkRequestCard.tsx`、`FeedbackRequestCard.tsx`、`GuestShareControls.tsx` |
| 履歴、リンク、ツール出力、アーティファクト | `MessagesTimeline.tsx`、`TimelineUserMessageRow.tsx`、`TimelineAssistantRows.tsx`、`ChatMarkdown.tsx`、`V2ItemInspector.tsx`、`ProposedPlanCard.tsx`、`McpAppFrame.tsx`、`externalLinkContextMenu.ts`、`runOutput.ts` |
| macOS の会話関連メニューとキー操作 | `DesktopWindow.ts` のネイティブ編集・画像メニュー、`DesktopApplicationMenu.ts` の Edit 操作、`packages/contracts/src/keybindings.ts` の該当コマンド |

## 抽出と照合

1. `git -C T3Audit-0.1.12/.source rev-parse HEAD` で対象リビジョンを確認する。
2. React の各入口とメニュー定義を読み、`onClick`、`onSelect`、`onValueChange`、キーバインド、サーバー権限に対応させる。動的ラベルはテンプレートまたは生成式として記録する。
3. スレッドの左クリック、ヘッダーのメニュー、サイドバーのコンテキストメニュー、パレットの生成行は同じ操作に対応する場合がある。共通メニューとパレットへの変換は `threadActionMenu.logic.ts` と `CommandPaletteThreadActions.tsx` で照合する。左ペイン固有のプロジェクト絞り込み、下書きメニュー、複数選択メニューは `Sidebar.tsx` で照合する。
4. `python3 T3Audit-0.1.12/inventory/CHAT/check.py --registries` でヘッダー、連番、重複、外部キー、各ポインタの存在と行範囲を確認する。併せて共通スレッド・下書きメニュー、外部リンクメニュー、詳細項目、アーカイブ操作、既定承認オプションの静的ラベルを列挙する。

## 条件と残る確認

- 判定欄は後続の実機確認で使う。初回アカウント、プロバイダーの返答、権限の組み合わせ、OS のネイティブ編集、リモート接続は静的コードから確認した。
- `{thread title}`、`{environment label}`、`/{command.name}` などは実行時に決まる。動的候補の全件はエージェント、登録データ、接続先の能力、環境設定に依存する。Snooze のラベルはローカルの日時と選んだ環境のプリセット設定で変わる。キーバインドは安定したコマンド ID を記録した。
- `entries.tsv` は原文の英語ラベルとコード識別子を使う。翻訳、サイズに応じた表示、警告の全組み合わせ、プロバイダーが生成するラベルは実機で確認する。
- 設定、PR、端末、統合ブラウザー、ワークフローはチャットからの入口と会話に返る結果を対象とする。独立した各画面や汎用ツールの内部は担当範囲外。構造化出力は会話の結果契約として `t3_submit_output` と `t3_thread_wait` を記録した。
