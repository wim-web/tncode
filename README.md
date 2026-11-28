# tncode

T3 Code (Beta) 0.1.12 を手本にした macOS ネイティブアプリ「Pi Workspace」（Swift／SwiftUI）。ビルド・操作・検証の手順は [PiWorkspace/README.md](PiWorkspace/README.md) にある。

| パス | 中身 |
|---|---|
| [PiWorkspace](PiWorkspace) | アプリ本体。Swift のソースとテスト、Pi・Codex の補助プロセス、検証スクリプト、日本語訳 |
| [reference/t3code](https://github.com/pingdotgg/t3code/tree/v0.1.12) | 手本にした T3 Code の公式ソース。タグ v0.1.12（`ca81b7b97a1c4b91e5ac25768d0f6629f37732fd`）のサブモジュール |
| [reference/screens](reference/screens/README.md) | T3 Code の全61画面の仕様と原本ソースの行、実測した寸法・色・余白 |
| [LICENSES/T3-Code.txt](LICENSES/T3-Code.txt) | T3 Code の権利表記。画面の文言と日本語訳は T3 Code の翻訳を流用している |

## 方針

- macOS の画面、プロジェクトとスレッドの選択、独立した新規データは Swift 側で管理する。[データモデル](PiWorkspace/Sources/PiWorkspace/Workspace.swift) · [操作モデル](PiWorkspace/Sources/PiWorkspace/WorkspaceModel.swift)
- 新しいワークスペースの実行役は Codex。Swift 版が Mac にインストール済みの `codex app-server` を起動する。Codex のログインをそのまま使え、初回はアプリの「ログイン…」から接続できる。既存のワークスペースでは「モデル設定 → 実行役 → Codex」で切り替える。送信済みの Pi 会話は引き続き Pi で開く。[Codex 認証](PiWorkspace/Sidecar/codex-login.mjs) · [Codex での会話](PiWorkspace/Sidecar/codex-agent.mjs) · [Pi での会話](PiWorkspace/Sidecar/worker.mjs)
- Codex の会話詳細には Web 検索のモードと Computer Use のツールの有無が出る。Mac のアプリ操作を頼むときは、入力欄の権限を「要承認」にすると、Codex から届くアプリごとの許可要求にその場で答えられる。[実行役の検証](PiWorkspace/scripts/verify-codex-agent.mjs)
- Pi の補助プロセスには `PI_TELEMETRY=0` と `PI_OFFLINE=1` を渡す。Codex 本体は手元の Codex 設定を使う。[起動設定](PiWorkspace/Sources/PiWorkspace/PiProcess.swift)
- 画面は T3 Code に合わせる。違いがあれば [reference/screens](reference/screens/README.md) と T3 Code のソースを正とする。

## 取得

```sh
git clone --no-recurse-submodules https://github.com/wim-web/tncode.git
cd tncode
git -c submodule.recurse=false submodule update --init --depth 1 -- reference/t3code
```

アプリのビルドに T3 Code のソースは要らない。画面を照合するときだけ取得する。T3 Code のソース内部には URL のない入れ子の gitlink があるため、上記の1階層だけを取得する。
