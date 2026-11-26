# デスクトップ・Web レンダラーの操作宣言

## 対象

T3 Code v0.1.12 のコミット `ca81b7b97a1c4b91e5ac25768d0f6629f37732fd`。`apps/web/src/` と `apps/desktop/src/` の Git 管理下にある `.tsx` を対象にした。アプリ構成の根拠は `AGENTS.md:118`、`apps/server/src/config.ts:293`、`apps/desktop/src/window/DesktopWindow.ts:464` と `:916`。このコミットの `apps/desktop/` に `.tsx` は 0 件で、対象 714 ファイルは共有レンダラーの `apps/web/src/` にある。

全ツリーの `.tsx` は 2,001 ファイル。内訳は Web 959、モバイル 567、参照用の `.repos/` 475。Web の除外 245 ファイルは `apps/web/src/` 内のテスト 242 と `apps/web/test/` の 3 ファイル。スキャナーの除外条件にはテスト、ストーリー、フィクスチャのパスと拡張子も含む。該当するストーリーファイルは 0 件。ファイル単位の抽出数と対象外のパスは [files.tsv](files.tsv) に載せた。

## 抽出単位

- JSX の開始タグまたは自己終了タグを 20,010 箇所解析した。HTML のフォーム要素、既知のコントロール名、リテラルの ARIA role、メニューやダイアログのトリガー、タブ、入力、リンク、編集領域、コールバック props、ドラッグ、展開 props を抽出した。同じタグ内の複数のコールバックは 1 行に記録した。明示された role をタグ名より優先した。
- JSX 外では `createElement`、Base UI の `useRender`、入力関連の `addEventListener`、ドラッグやポインターのフック、ショートカット登録、UI コールバックやラベル付き選択肢を持つオブジェクトを抽出した。候補行にはイベントを中継するコンポーネントや装飾要素の props 展開も含む。
- レンダラーの `contextMenu.show` を 15 箇所検出した。同じ TSX 内の配列、条件分岐、`push` と `unshift`、ローカルな生成関数の戻り値、サブメニュー、`map` などをたどった。結果は項目宣言 46 行と未展開の入力・変換 13 行。条件で変わる項目や依存先から得る項目があるため、メニューの表示項目数は実行時に変わる。
- ラベルは `aria-label`、`label`、`title` などの props、子テキスト、翻訳呼び出し、隣接するツールチップから採取した。値は `static`、`localized`、`dynamic`、`reference` のいずれかで記録した。長い式は先頭を残した。添付の行・列番号で完全な式を確認できる。

## 集計の読み方

[entries.tsv](entries.tsv) の 5,733 行は、581 ファイルで見つかったソース宣言と候補。133 ファイルでは該当行がなかった。3,640 行にラベルの根拠がある。入力のない再利用ラッパーや利用箇所、生成処理や生成先の JSX は別々の宣言として現れる。

[features.tsv](features.tsv) の 1,491 件は、ファイルと宣言を所有するコンポーネントまたは関数ごとのグループ。コンテキストメニューは名前付きの開閉ハンドラーを使って分けた。各グループに `UI-` ID を付け、すべての `UI-E` を 1 件のグループにつないだ。画面での再生に使えるよう、ラベルやハンドラーの手掛かりを各グループに載せた。979 件は通常の製品ソース、199 件は汎用 UI、312 件は操作候補だけのグループ、1 件は開発用。これらの件数は宣言を追うための単位であり、製品のユニークな操作や画面の数は実行時の確認とワークフロー単位の突き合わせで確定する。

`primitive` は `components/ui/` 内の定義。ほかのパスにある複合コンポーネントの再利用性は所有者名と呼び出し元で確認する。`candidate` は props 展開のみ、ツールチップ、フォーカス補助、設定オブジェクトなどの確認候補。`delegated` は `render` または `asChild` による委譲。`generated` は反復内、動的タグ、データを通すメニュー生成など。`dynamic-label` は文字列が式や参照で決まる。`conditional` は構文上の分岐またはゲート props の手掛かり。`spread` は展開構文。`opaque` は実行時に値を決める入力や追跡範囲外の処理。`dev` は開発条件のある宣言。フラグは重複する。集計の詳細は [summary.json](summary.json) にある。

## 残る範囲

抽出は構文とファイル内の束縛を使う。任意の部品の呼び出し先、props 展開の値、動的な JSX、翻訳後の文字列、表示条件、キーボードの割り当て、権限、実行経路の到達性は実行時のデータに依存する。命名・role・props から識別できないカスタム部品や、対象 API 以外の手段で生成される操作は残る。画面上で同じ操作を呼ぶ箇所や、同じ宣言から展開される多数の項目を統合するには各ワークフローとの照合が必要。

Electron のメインメニューとプリロード、`.ts` のショートカットやメニューの定義、依存ライブラリと WebView 内の DOM、外部プロバイダー、生成ドキュメントは TSX 分母の範囲外。項目を供給する代表的な範囲外の定義は `apps/web/src/components/threadActionMenu.logic.ts:42` と `:158`、`apps/web/src/fileContextMenu.ts:114`、`apps/web/src/components/chat/externalLinkContextMenu.ts:95`。ゲスト、デバイス、プロバイダー、権限、接続方式で変わる条件は対象行から追跡する。

## 再生成

Node.js 22 以降、Git、TypeScript 5.9.3 を使う。[scan.mjs](scan.mjs) は `.source` の HEAD を照合し、固定コミットの Git blob を読む。TypeScript がスクリプトから解決できる位置にあるときは `--typescript` を省略できる。チェックアウトの場所を変えた場合は `--repo` で指定する。

```sh
node T3Audit-0.1.12/inventory/UI/scan.mjs --typescript /path/to/typescript/lib/typescript.js
node T3Audit-0.1.12/inventory/UI/scan.mjs --check --typescript /path/to/typescript/lib/typescript.js
```

`--check` は 4 つの生成物をバイト単位で照合する。また、独立したチェックで Git のファイル一覧、TSV のヘッダーと ID、全行の参照先、行・列、フラグと分類の集計、およびタブ、メニュー、ドラッグ、エディター、汎用ボタンの実例を照合した。
