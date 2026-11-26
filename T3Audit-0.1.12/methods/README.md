# 再現手順

台帳・固定ソース・公開用データの検査は、リポジトリ直下から `python3 T3Audit-0.1.12/methods/verify-public.py` を実行する。ダウンロード済みのデータだけを読み、Git と Python 3.9 以降を使う。以下の GUI 再現には macOS と該当する配布アプリが必要。

## T3 の隔離した原本

監査ディレクトリをカレントディレクトリにする。配布版 T3 Code (Beta) 0.1.12、Python 3、Git、Node.js を用意する。動画の採取には ffmpeg を使う。起動器は新規テストプロファイルとローカルのポートを必要とする。既存の Dev プロファイルがある場合は停止する。

```sh
cd T3Audit-0.1.12
scratch=$(mktemp -d)
fixture="$scratch/original"
python3 methods/desktop_fixture.py prepare "$fixture"
export T3_AUDIT_OUTPUT="$scratch/receipts"
python3 methods/desktop_fixture.py run "$fixture"
```

別ターミナルでも `fixture` と `T3_AUDIT_OUTPUT` に同じパスを設定する。

1. Welcome で **Start without an agent**、次に **Add project → Local folder**。`$fixture/Audit Project/` を指定する。
2. `python3 methods/desktop_fixture.py attach-turns "$fixture"` を実行する。下書きから `fixture stream` を送り、部分応答と完了を照合する。`fixture approval` は Supervised で拒否と承認を別々に試す。`fixture interrupt` の実行中に停止し、`fixture fail` では途中出力とエラーを比較する。
3. New worktree の選択前後と初回送信後の `git worktree list --porcelain` を比較する。専用 fixture で `python3 methods/worktree-obstruction.py "$fixture" block` を実行して準備を失敗させ、`restore` 後に Retry。送信文、スレッド、作業先と応答を追う。
4. `node methods/drive.mjs "$fixture" quit` で検証用アプリだけを終了する。同じ fixture を再起動し、一覧から同じ会話を選び `fixture resume` を送る。単一プロバイダーのプロトコルは `python3 methods/turn-fixture/verify.py` でも検査できる。

## Swift との比較

[PiWorkspace のビルド・検証](../../PiWorkspace/README.md) を参照する。macOS の補助機能へのアクセスは配布アプリを AX で操作する場合に必要。画像収録の許可がない検証は、実配布版の AX 操作と、同じ Swift ソースを使った補助ビルドの描画を個別に記録する。

```sh
# リポジトリ直下で実行。project は上で作成したテストフォルダーの絶対パス。
methods="$PWD/T3Audit-0.1.12/methods/swift-capture"
pi="$PWD/PiWorkspace"
tools_dir=$(mktemp -d)
mkdir "$tools_dir/output"
(cd "$pi" && ./scripts/build-app.sh)
bash "$methods/build-driver.sh" "$pi" "$tools_dir"
swiftc -module-cache-path "$tools_dir/cache" "$methods/inspect.swift" -o "$tools_dir/inspect"
swiftc -module-cache-path "$tools_dir/cache" "$methods/preflight.swift" -o "$tools_dir/preflight"
bash "$methods/build-render.sh" "$pi" "$tools_dir/render"
node "$methods/record.mjs" "$tools_dir" "$pi/dist/Pi Workspace.app" "$tools_dir/output" installed "$project"
node "$methods/record.mjs" "$tools_dir" "$tools_dir/render/Pi Workspace Audit Render.app" "$tools_dir/output" render "$project"
```

`methods/layout-experiment/run.sh` は独立した SwiftUI/AppKit 配置候補を一時ディレクトリでビルドする。`node methods/check-pi-telemetry.mjs` は、PiWorkspace/Sidecar の npm 依存をインストールした状態で、その SDK に対する Swift の既定値を確認する。後者はネットワークの全量検査ではない。
