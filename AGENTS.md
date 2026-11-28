# エージェント向けの決まり

## 実機テストは止めている

ユーザーが再開を指示するまで、ビルドしたアプリを起動して確かめる実機テストはしない。ユーザーが使っている画面にウィンドウが出たり消えたりし、キーボードの入力先やマウスカーソルを奪うため。バックグラウンド用のシナリオでもウィンドウと Dock アイコンは出る。

使ってよい確認:

- `swift build`、`swift build --build-tests`
- `swift test`（`--filter` 付きも含む）。ウィンドウを作るテストは、`TNCODE_TEST_DESKTOP=dedicated` がないと最初に skip する
- `node scripts/verify-headless.mjs`（ウィンドウを作らないテストをすべて走らせ、ウィンドウを作るテスト以外の skip を失敗にする）
- `./scripts/build-app.sh` でのビルド（起動はしない）

しないこと:

- `dist/tncode.app` やその実行ファイルを起動するスクリプト、`scripts/ax.swift`（`.build/ax`）でアプリを操作するスクリプトを実行する。`verify-app.mjs` とそのすべてのシナリオ（`--*-only` も含む）、`verify-commit-generation.mjs`、`verify-default-telemetry.mjs`、`verify-draft-links.mjs`、`verify-file-drops.mjs`、`verify-native-paste.mjs`、`verify-side-chat.mjs`、`verify-sidebar-thread-pointer.swift`、`verify-startup-recovery.mjs`、`verify-stop-retry.mjs`、`verify-text-attachment-save.mjs`、`verify-welcome-projects.mjs` などが当たる
- `open` などでビルドしたアプリを開いて、見た目や動きを確かめる
- ガードを抜けるために `TNCODE_TEST_DESKTOP=dedicated` を設定する

実機でしか確かめられない変更は、作業の報告で「実機では確認していない項目」として挙げる。

## ウィンドウを作るテストを書くとき

`NSWindow` や `NSPanel` を作るテスト、`finishLaunching()` を呼ぶテストは、テスト関数の最初の行で `try requireTestDesktop()` を呼ぶ（`Tests/tncodeTests/TestDesktop.swift`）。ウィンドウを作るヘルパーや fixture の初期化でも、ウィンドウより前に呼ぶ。ウィンドウを画面の外に置いても、キーの入力先、シート、メニュー、ポップオーバー、子ウィンドウはユーザーの画面とキーボードに届く。
