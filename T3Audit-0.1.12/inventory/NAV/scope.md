# NAV の調査範囲

対象は T3 Code v0.1.12 の `.source`、コミット `ca81b7b97a1c4b91e5ac25768d0f6629f37732fd`。ソースから確認した 248 の操作・結果と 790 の入口・識別子を収録した。各入口の `feature_id` は対応する再現手順を指す。複数のキーや UI から同じ操作を呼ぶ場合は、同じ手順を参照する。

## Web ルート

- `apps/web/src/router.ts:6` が使う `routeTree.gen.ts` の `fullPath` を、`apps/web/src/routes` の宣言に結び付けた。46 のファイルルートと 1 つのルートレイアウトがある。`/_chat` レイアウトとインデックスの公開パスはともに `/`。ルートレイアウト自体の識別子は `__root__`。
- `__root.tsx:66` と `_chat.tsx:33` で認証とホスト型 Web の分岐を確認した。`/guest`、ホスト型のペアリング、CLI とエージェントの承認経路には固有の条件がある。`/threads/$environmentId/$threadId` と `/projects/$projectKey` は置換遷移を記録した。Settings と Usage は共通のルートモーダルを使う。参照先は `apps/web/src/components/sidebar/mainAppLocation.ts:8` と `apps/web/src/components/AppRouteModal.tsx:72`。
- 設定は `_chat.settings.tsx:48` と `:181` のスコープ境界を通る。`settingsSearch.ts:1560` の旧パスは設定ハッシュを優先する。Secrets の直リンクは全環境の報告後に対応フラグを評価する。登録済みパスとサイドバー・パレットの表示可否は別々に判断される。

## ネイティブメニューとデスクトップ

- `apps/desktop/src/window/DesktopApplicationMenu.ts:239` のメニューテンプレートに 46 のラベル出現箇所がある。非表示の項目、macOS のアプリメニュー、その他の OS の File、Windows の Exit、Help の更新確認を含む。区切り線は項目数から外した。22 件の明示的な Electron role と、プラットフォーム別の代替値を展開した 16 件の明示的な accelerator を収録した。
- Electron が role から補うアクセラレーターと macOS が列挙する Services は、固定チェックアウトから確定できるラベルやキーには含めていない。英語ラベルは `msg` の値で、保存された表示言語を適用すると変わる。参照先は `DesktopApplicationMenu.ts:434`。
- `DesktopWindow.ts:663` の固定コンテキストテンプレートから 10 件の項目を収録した。辞書候補は実行時の値で最大 5 件。編集 role の有効状態を決めるのはクリック先の文書の editFlags。レンダラー個別の機能が `ElectronMenu.ts:256` の汎用 IPC に渡すメニューは実行時データとして扱う。
- `DesktopApp.ts:416`、`DesktopLifecycle.ts:284`、`DesktopClerk.ts:126`、`DesktopWindow.ts:335`、`DesktopStartupRecovery.ts:239` を追跡した。macOS の Dock 再表示、ウィンドウ履歴のスワイプ、ウィンドウ境界、起動回復、OS からのリンク、フォーカスされた DevTools、`QuitHold.ts`、SnapShot のグローバル割り当てを含む。SnapShot の既定形式は左右 Shift の同時押しで、機能自体は初期設定で無効。Niri の `Ctrl+Shift+2` は設定テンプレートの値。
- 本体とゲストのズーム・再読込、スレッドや右パネルの `CmdOrCtrl+W`、ネイティブメニューの Close Window は異なる経路を持つ。ゲスト側の編集キー判定と転送は `apps/desktop/src/preview/Manager.ts:449`、`:518`、`:1552` にある。Find とズームの一部はページ側にキーを渡してから未処理時に転送する。ゲスト内のページやフレームによって処理結果が変わる。

## キー割り当て

- `packages/contracts/src/keybindings.ts` の登録済み静的識別子は 91 件。別途 `script.<id>.run` があり、`id` は最大 24 文字、先頭は英小文字か数字、残りにハイフンも使える。
- `packages/shared/src/keybindings.ts:58` の既定値は 74 の個別規則と、`thread.jump.*` と `modelPicker.jump.*` を展開した 18 規則。合計 92 件。`mod` は macOS で Command、他の OS で Ctrl。各行に `when` がある場合は原文を残した。番号キーは Electron のみで、モデルピッカーの開閉によって対象が変わる。端末の前後移動は macOS 用と他 OS 用の両方を収録した。
- 既定の割り当てがない識別子は `composer.cycleHost`、`composer.decreaseEffort`、`composer.increaseEffort`、`rightPanel.toggleMaximized`、`thread.regenerateTitle`、`thread.stop`。対応する実装と、キーを割り当ててから確認する手順を記録した。
- `apps/web/src/keybindings.ts:126` の送信設定では、一部の Mod+Enter 規則を実行時に Shift 付きへ変換する。同ファイルの `:195` は有効な設定を末尾から照合する。`apps/server/src/keybindings.ts:97` と `:530` は既存設定に追加する条件付きの移行規則で、既定 92 件の集計には重ねて加えていない。
- `apps/web/src/shortcuts/dispatcher.ts:47`、`:74`、`:99`、`chatRouteCommands.ts:139`、`commandPaletteCommands.ts:65` と各画面のハンドラーを追跡した。キー規則の一致に加えて、対象ルート、フォーカス、ダイアログ、権限、実行時の環境設定が適用される。OS またはブラウザーが先に処理するキーや、利用者が保存した割り当ては実機で照合する。

## コマンドパレット

- `apps/web/src/components/CommandPalette.tsx`、`.logic.ts`、`CommandPaletteProjectItems.tsx`、`CommandPaletteThreadItems.tsx`、`CommandPaletteThreadActions.tsx`、`CommandPaletteThemeItems.tsx`、`CommandPalettePortForwardItems.tsx`、`CommandPaletteContent.tsx` を追跡した。入口、ルートの操作、サブメニュー、候補グループ、フォルダー選択、キー操作を収録した。先頭の `>` は操作候補に絞る。空のクエリでは操作と最近のスレッドを使い、通常の検索ではスレッド、プロジェクト、設定、メッセージなどの候補を生成する。
- `threadActionMenu.logic.ts:158` の現スレッド操作は、パレット用変換の条件を適用した。Rename と元の Project settings は変換時に外れ、Share with guest と Project settings にはパレット独自の項目がある。元の project filter はこの呼び出しで無効。Snooze の既定候補は 5 件で、候補値は設定や現在時刻に依存する。
- 設定検索は 171 件の固定 ID と静的コマンド由来の 91 件のアンカーを記録した。ホスト定義の `settings` から生成される 4 件も収録した。実際の表示条件は `settingsSearch.ts:1676` と `:1701` にある。ソース提供元、接続先、プロジェクト、スレッド、メッセージ、パス、カスタムテーマ、ポートはデータから候補を生成するため、代表値ではなく生成式を収録した。組み込みテーマ 5 件と固定の外観 3 値を展開した。
- チャットのスラッシュメニュー、個別ビューの汎用編集・フォーム操作、サーバーの HTTP・RPC エンドポイント、マーケティングサイトとモバイルのルートは、今回のアプリナビゲーションの対象外。

## 再集計

ワークスペースから `python3 T3Audit-0.1.12/inventory/NAV/verify.py` を実行する。スクリプトはコミット、ヘッダー、ID、参照先の行を確認する。ルート・コマンド・既定規則・設定検索 ID を再抽出し、メニューと主要パレットの固定定義の行を照合する。現在の OS、環境の状態、辞書候補、履歴、権限を必要とする項目は各 TSV の `gate` と `acceptance` を使って実機で確認する。この調査ではアプリを起動していない。
