# 機能台帳

[features.tsv](features.tsv) は `id` をキーに、原本の操作手順・前提・中間状態・結果・失敗からの復帰・保存先・実装位置・実機の検証条件と、Swift の実装状況・根拠行・受入条件を1行にまとめた表。`source` は固定した T3 ソース、`swift_source` は PiWorkspace からの相対パスと行番号。1項目に複数の参照先がある場合は縦線で区切っている。

| 領域 | 対象 | 行数 | 入口宣言数 |
|---|---|---:|---:|
| [NAV](NAV/scope.md) | ルート、ネイティブメニュー、ショートカット、パレット | 248 | 790 |
| [CHAT](CHAT/scope.md) | プロジェクト、スレッド、送信、承認、キュー | 297 | 716 |
| [DEV](DEV/scope.md) | Git、worktree、PR、端末、ファイル、右パネル | 355 | 737 |
| [CFG](CFG/scope.md) | 設定、Labs、スコープと表示条件 | 369 | 1,128 |
| [HOST](HOST/scope.md) | 実行環境、プロバイダー、接続と共有 | 225 | 760 |
| [RPC](RPC/scope.md) | 通信と内部処理 | 87 | 899 |
| [UI](UI/scope.md) | レンダラーの宣言を親コンポーネントなどでまとめた単位 | 1,491 | 5,733 |

[entries.tsv](entries.tsv) はソース上の入口10,763件を対応する `feature_id` へ結ぶ。同じ操作のボタンとキー割当などは別の登録として数える。[runtime-entries.tsv](runtime-entries.tsv) は実機で識別した1,091件について、ID・画面・役割・帰属を収録する。実行時に生成される端末入力とフォント試写用入力には RT ID がある。[実行時追加分の Swift 照合](../comparison/runtime-only.tsv)

`記載した遷移を実行` はその行に記録した手順まで、`画面・状態に到達` は表示先まで、`表示を観測` は入口の存在まで。画像非公開のため公開版では [結果の要約](../results/transitions.tsv) と [数値化した画面](../screens/states.tsv) を引ける。[検証条件の残る1,427行](unverified.tsv) · [原本の収集時ハッシュ](freeze.json)
