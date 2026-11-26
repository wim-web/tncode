# Pi の Keychain 認証経路

SDK 用補助プロセスを再起動し、Swift の macOS Keychain から読んだ使い捨て資格情報で、認証付きループバック経由のモデル要求が通るかを調べる独立試験。

macOS、Swift コンパイラ、Node.js 22.19 以降、npm を用意する。Ollama に `smollm2:135m` をロード可能にし、ローカルのポート18541で待ち受けさせる。このディレクトリで次を実行する。

```sh
npm ci --ignore-scripts --no-audit --no-fund
node verify.mjs
```

調査時はキーなしで401、補助プロセスを再起動後、認証付き1要求で HTTP 200・正常な終了理由を確認した。テストは一時 Keychain 項目を削除し、作業・設定ディレクトリ・ログをスキャンした。`auth.json` と平文の試験キーは見つからなかった。新しい試験では自分の `run-*` に記録が作られる。[本実装の Keychain 管理](../PiWorkspace/Sources/PiWorkspace/KeyVault.swift)
