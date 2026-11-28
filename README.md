# tncode

ローカルのプロジェクトで Codex・Pi と会話する macOS ネイティブアプリ（Swift／SwiftUI）。画面は [T3 Code](https://github.com/pingdotgg/t3code) v0.1.12 を手本にしている。

tncode は T3 Code の非公式な派生プロジェクトで、T3 Tools Inc. とは関係がなく、承認も受けていない。

## ビルドして開く

Xcode（Swift 6.2 以降）と Node.js 22.19 以降・npm を用意し、リポジトリの直下で実行する。

```sh
./scripts/build-app.sh
open dist/tncode.app
```

Codex で会話するには Mac に Codex を入れておく。使い方は [docs/guide.md](docs/guide.md) にある。

## 構成

| パス | 中身 |
|---|---|
| [Sources](Sources) · [Tests](Tests) | アプリのソースとテスト |
| [Sidecar](Sidecar) | Codex・Pi を動かす補助プロセス（Node.js） |
| [Localization](Localization) | 英語・日本語の文言 |
| [scripts](scripts) | ビルドと検証のスクリプト |
| [reference](reference) | 手本にした T3 Code の画面仕様 |
| [ThirdPartyNotices](ThirdPartyNotices) | T3 Code の MIT License |
