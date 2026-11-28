# T3 Code v0.1.12 画面リファレンス

対象は [`reference/t3code`](../../t3code) のタグ `v0.1.12`、コミット `ca81b7b97a1c4b91e5ac25768d0f6629f37732fd`。Electron と Web が使う `apps/web/src` と、その表示条件を決める公開ソースを参照した。寸法は CSS 宣言、レイアウト計算、Electron のウィンドウ設定に基づく。OS の外枠やフォントによる差は実機の計測欄に記録できる。

| リファレンス | 範囲 |
| --- | --- |
| [ワークスペースとサイドバー](01-workspace.md) | SRC-S01〜S08。ホーム、下書き、スレッド、フォーカス、サイドバー、狭幅、テーマ。 |
| [右パネル、カード、プレビュー](02-panels.md) | SRC-S09〜S19。シートと横並び、タブ、Thread details、Diff、Terminal、Files、Browser、Device、PR、Issue、子スレッド。 |
| [Composer と会話の状態](03-conversation.md) | SRC-S20〜S27。入力、モデル、送信、Transcript、承認、質問、計画、Find。 |
| [ナビゲーション、初回起動、通知](04-navigation.md) | SRC-S28〜S36。オーバーレイ、一覧、Welcome、ペアリング、エラー、ネイティブの窓制御。 |
| [設定の画面とタブ](05-settings.md) | SRC-S40〜S64。設定のシェル、22 タブと詳細画面、互換ルート。 |
| [再現実験](06-experiments.md) | 画面 ID と結び付けた入力条件、操作、観測ポイント。 |
| [state-index.tsv](state-index.tsv) | UTF-8。`state_id`、`screen_intent_ja`、`reference`、`source_commit`、`source_locations`。最終列はリポジトリ相対 `path:line-range` を ` | ` で連結する。 |

CSS の `rem` は実行時の root font size に従う。Tailwind の標準トークンは対応する `rem` で示す。px の数値は該当ソースが使う CSS px またはレイアウト計算の値。Electron のウィンドウ寸法は DIP。`max-sm`、`max-md` などは viewport の条件、`@min-[32rem]/settings-row` のような条件は要素コンテナの寸法。文字サイズやズームで境界の見え方が変わるため、実機記録には viewport、ブラウザー／ウィンドウのズーム、テーマ、環境と権限も残す。

Tab 順はソースにある描画順、表示条件、フォーカス指定を記載した。F6 の領域巡回は固有の順を持つ。Base UI のダイアログとメニュー、ファイルツリー、Ghostty、Electron の webview にはそれぞれのフォーカス境界がある。`SRC-S01` のような ID を使うと、照合結果から本文と根拠へ移動できる。
