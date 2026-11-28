# tncode

ローカルのプロジェクトで Codex・Pi と会話する macOS ネイティブアプリ（Swift／SwiftUI）。画面は [T3 Code](https://github.com/pingdotgg/t3code) v0.1.12 を手本にしている。

tncode は T3 Code の非公式な派生プロジェクトで、T3 Tools Inc. とは関係がなく、承認も受けていない。

## ビルドして開く

Xcode（Swift 6.2 以降）と Node.js 22.19 以降・npm を用意し、リポジトリの直下で実行する。

```sh
./scripts/build-app.sh
open dist/tncode.app
```

使い方と検証の手順は [docs/guide.md](docs/guide.md) にある。

## 構成

| パス | 中身 |
|---|---|
| [Sources/tncode](Sources/tncode) · [Tests/tncodeTests](Tests/tncodeTests) | アプリのソースとテスト |
| [Sidecar](Sidecar) | Codex・Pi を動かす補助プロセス（Node.js） |
| [Localization](Localization) | 英語・日本語の文言 |
| [scripts](scripts) | ビルドと実機検証のスクリプト |
| [reference/t3code](https://github.com/pingdotgg/t3code/tree/v0.1.12) | 手本にした T3 Code のソース。タグ v0.1.12（`ca81b7b97a1c4b91e5ac25768d0f6629f37732fd`）のサブモジュール |
| [reference/screens](reference/screens/README.md) | T3 Code の全61画面の仕様と原本ソースの行、実測した寸法・色・余白 |
| [ThirdPartyNotices](ThirdPartyNotices) | 流用した他者の著作物の権利表記。T3 Code の文言と日本語訳を流用しているので、その MIT License を置いている。ビルド時にアプリの「Open source licenses」にも入る |

## 方針

- macOS の画面、プロジェクトとスレッドの選択、独立した新規データは Swift 側で管理する。[データモデル](Sources/tncode/Workspace.swift) · [操作モデル](Sources/tncode/WorkspaceModel.swift)
- 新しいワークスペースの実行役は Codex。tncode が Mac にインストール済みの `codex app-server` を起動する。Codex のログインをそのまま使え、初回はアプリの「ログイン…」から接続できる。既存のワークスペースでは「モデル設定 → 実行役 → Codex」で切り替える。送信済みの Pi 会話は引き続き Pi で開く。[Codex 認証](Sidecar/codex-login.mjs) · [Codex での会話](Sidecar/codex-agent.mjs) · [Pi での会話](Sidecar/worker.mjs)
- Codex の会話詳細には Web 検索のモードと Computer Use のツールの有無が出る。Mac のアプリ操作を頼むときは、入力欄の権限を「要承認」にすると、Codex から届くアプリごとの許可要求にその場で答えられる。[実行役の検証](scripts/verify-codex-agent.mjs)
- Pi の補助プロセスには `PI_TELEMETRY=0` と `PI_OFFLINE=1` を渡す。Codex 本体は手元の Codex 設定を使う。[起動設定](Sources/tncode/PiProcess.swift)
- 画面は T3 Code に合わせる。違いがあれば [reference/screens](reference/screens/README.md) と T3 Code のソースを正とする。
- 旧名 Pi Workspace のときに保存したデータ・設定・API キーは、初回起動時に tncode へ引き継ぐ。[引き継ぎ処理](Sources/tncode/RenameMigration.swift)

## T3 Code のソースを取得する

アプリのビルドには要らない。画面を照合するときだけ取得する。

```sh
git -c submodule.recurse=false submodule update --init --depth 1 -- reference/t3code
```

T3 Code のソース内部には URL のない入れ子の gitlink があるため、上記の1階層だけを取得する。
