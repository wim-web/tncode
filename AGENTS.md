# エージェント向けの決まり

## 実機テストは止めている

ユーザーが再開を指示するまで、ビルドしたアプリを起動して確かめる実機テストはしない。ユーザーが使っている画面にウィンドウが出たり消えたりし、キーボードの入力先やマウスカーソルを奪うため。バックグラウンド用のシナリオでもウィンドウと Dock アイコンは出る。

使ってよい確認:

- `swift test`（ウィンドウは画面の外に作られ、Dock にも出ない）
- `node scripts/verify-headless.mjs`
- `./scripts/build-app.sh` でのビルド（起動はしない）

しないこと:

- `dist/tncode.app` やその実行ファイルを起動するスクリプト、`scripts/ax.swift`（`.build/ax`）でアプリを操作するスクリプトを実行する。`verify-app.mjs` とそのすべてのシナリオ（`--*-only` も含む）、`verify-commit-generation.mjs`、`verify-default-telemetry.mjs`、`verify-draft-links.mjs`、`verify-file-drops.mjs`、`verify-native-paste.mjs`、`verify-side-chat.mjs`、`verify-sidebar-thread-pointer.swift`、`verify-startup-recovery.mjs`、`verify-stop-retry.mjs`、`verify-text-attachment-save.mjs`、`verify-welcome-projects.mjs` などが当たる
- `open` などでビルドしたアプリを開いて、見た目や動きを確かめる
- ガードを抜けるために `TNCODE_TEST_DESKTOP=dedicated` を設定する

実機でしか確かめられない変更は、作業の報告で「実機では確認していない項目」として挙げる。
