# tncode

T3 Code (Beta) 0.1.12 を Swift／SwiftUI の macOS アプリへ移植するための調査・実装引き継ぎ。Swift 版のビルド・操作・実機検証の手順は [PiWorkspace](PiWorkspace/README.md) にある。

**実装を担当する人は [準備から完成までの実装手順書](IMPLEMENTATION.md) から始める。** 全12工程の実装順、依存関係、各工程の終了条件を記載した。[工程別の作業表](docs/implementation-order.tsv) から担当する機能・画面の ID を引ける。

| 実装時に調べたいこと | 資料 |
|---|---|
| 機能、入口、途中状態、失敗・復帰、外部への作用 | [機能台帳の索引](T3Audit-0.1.12/inventory/README.md) · [全機能と Swift の差分](T3Audit-0.1.12/inventory/features.tsv) |
| 画面の寸法、文字、色、余白、フォーカス、キーボード操作 | [UI 再現仕様・配置図](T3Audit-0.1.12/screens/README.md) · [61画面の原本ソース](T3Audit-0.1.12/screens/source/README.md) |
| 移植開始時の Swift 版との差分と受入条件 | [機能別の差分](T3Audit-0.1.12/comparison/README.md) · [61画面の照合表](T3Audit-0.1.12/comparison/screens.tsv) |
| 実機で再現した操作と検証範囲 | [テスト条件・結果](T3Audit-0.1.12/results/README.md) · [実行した遷移](T3Audit-0.1.12/results/transitions.tsv) · [未確認項目](T3Audit-0.1.12/inventory/unverified.tsv) |

原本は [公式タグ v0.1.12](https://github.com/pingdotgg/t3code/releases/tag/v0.1.12)。配布物に埋め込まれたコミットと `ca81b7b97a1c4b91e5ac25768d0f6629f37732fd` が一致した。調査した操作・設定・分岐は **1,494行**。操作結果を実機で確認したものが67行、画面到達まで62行、表示まで266行、ソース確認のみ1,099行。通信と UI 実装の内訳を含む3,072行すべてに Swift の対応と受入条件がある。[来歴](T3Audit-0.1.12/results/reference-build.json) · [集計](T3Audit-0.1.12/inventory/summary.json)

## 確定している移植方針

- macOS の画面、プロジェクトとスレッドの選択、独立した新規データは Swift 側で管理する。[データモデル](PiWorkspace/Sources/PiWorkspace/Workspace.swift) · [操作モデル](PiWorkspace/Sources/PiWorkspace/WorkspaceModel.swift)
- エージェントは補助プロセス内の Pi SDK を使う。API キーは Swift 側が macOS Keychain に保存し、補助プロセスの CredentialStore がプロセス間通信で読み出す。[Keychain](PiWorkspace/Sources/PiWorkspace/KeyVault.swift) · [Pi の起動](PiWorkspace/Sources/PiWorkspace/PiProcess.swift) · [SDK への組み込み](PiWorkspace/Sidecar/worker.mjs) · [認証の先行試作](pi-keychain-probe/README.md)
- **Swift 版のテレメトリは既定オフ。** 新規データで利用統計や診断の外部送信を自動で有効にしない。現行版は `PI_TELEMETRY=0` と `PI_OFFLINE=1` を補助プロセスに渡す。利用者が選んだモデル API に対する会話の送信は別の機能である。SDK の判定は同梱版で確認済み。起動・初回送信・再起動時の全プロセスの通信先照合は、今後の受入項目。[設定箇所](PiWorkspace/Sources/PiWorkspace/PiProcess.swift#L83) · [判定結果](T3Audit-0.1.12/results/pi-telemetry.json) · [原本の送信仕様](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/docs/user/telemetry.md)

## 最初に通す3つの操作

1. **既存フォルダーを開く**（CHAT-058、DEV-001、NAV-232）。空の状態から登録、下書きの表示、入力フォーカス、キャンセルまで照合する。Swift 配布版で直接入力と Browse から登録し、取消・無効パス・同じフォルダーの再登録を確認した。
2. **会話を送って続ける**（CHAT-001、088、089、100）。初回送信で中央の下書きから会話画面へ移ること、先頭の応答、停止、失敗、再起動後のスレッド ID と履歴を照合する。原本で再起動直後に開いたのは直近のプロジェクトの新規下書き。保存済みの会話は一覧から開いて続行できた。
3. **作業先と再試行**（DEV-004、012、023、024）。worktree を選択した時点と、最初の送信後の Git 状態を区別する。原本では準備に失敗すると、作成されたスレッドに送信文と失敗ステージが残り、Retry で同じスレッドから再開できた。

## 取得・検査

```sh
git clone --no-recurse-submodules https://github.com/wim-web/tncode.git
cd tncode
git -c submodule.recurse=false submodule update --init --depth 1 -- T3Audit-0.1.12/.source
python3 T3Audit-0.1.12/methods/verify-public.py
```

T3 原本内部の参照用ツリーには URL のない入れ子の gitlink があるため、ここでは上記の1階層だけを取得する。検査には Python 3.9 以降と Git を使う。clone した後は `T3Audit-0.1.12/index.html` をブラウザーで開くと、オフラインで機能 ID、登録名、実機入口 ID を検索できる。GitHub 上では上の Markdown の索引から読める。`T3Audit-0.1.12/.source` は固定した公式ソースのサブモジュール。[テスト環境での操作手順](T3Audit-0.1.12/methods/README.md) · [T3 Code の権利表記](LICENSES/T3-Code.txt)

公開版には、原本の181回の画面採取と Swift 配布版13状態から取り出した構造・座標、状態と結果の要約を収録した。実機のスクリーンショット、録画、DOM・Accessibility の生出力、端末ログ、プロファイル、認証情報は公開対象外。配置図は寸法から作成した説明用の図で、画素比較用の写真ではない。
