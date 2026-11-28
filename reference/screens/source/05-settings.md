# 設定の画面とタブ

[索引](README.md)

<a id="SRC-S40"></a>

## SRC-S40 設定シェル、検索、スコープ

- `/settings` は General に置換する。設定は [SRC-S36](04-navigation.md#SRC-S36) のルートモーダルを使う。右ヘッダーは高さ `3rem`。左のナビゲーションは幅 `15rem`、`max-md` でアイコンの `3.5rem` に切り替わる。狭幅で検索を開くと、ナビが本文の上へ全幅で広がる。現在タブに `aria-current="page"`。[_chat.settings.tsx L143–220](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/routes/_chat.settings.tsx#L143-L220) [SettingsSidebarNav.tsx L261–277](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/SettingsSidebarNav.tsx#L261-L277) [SettingsSidebarNav.tsx L372–437](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/SettingsSidebarNav.tsx#L372-L437)
- 本文は settings のスクロール領域。`WorkspacePageContainer` は幅 100%、最大 `56rem`（readable）、`64rem`（wide）、`72rem`（expanded）。左右 `1.25rem`、`sm` で `1.5rem`、上 `1.5rem`、下 `3rem`。行は `32rem` のコンテナ境界で縦積みから説明＋操作の 2 列に変わる。行とセクションは検索でプログラムフォーカスでき、通常の Tab は行内のコントロールへ進む。設定タブの順は下記の登録順。[WorkspacePageContainer.tsx L5–27](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/WorkspacePageContainer.tsx#L5-L27) [settingsLayout.tsx L528–576](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/settingsLayout.tsx#L528-L576) [settingsLayout.tsx L625–678](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/settingsLayout.tsx#L625-L678) [settingsSearch.ts L140–190](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/settingsSearch.ts#L140-L190)
- `Cmd/Ctrl+F` または入力欄以外の `/` で検索へフォーカス、↑/↓ で候補を循環、Enter でハッシュ付きタブへ移動して対象行を表示、Esc で検索語を消す。検索結果自体は `tabIndex=-1` で入力の `aria-activedescendant` を使う。設定変更に必要な scope を満たせない場合は、対応する環境・プロジェクト等を選ぶ通知を出す。[SettingsSidebarNav.tsx L159–259](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/SettingsSidebarNav.tsx#L159-L259) [SettingsSidebarNav.tsx L281–367](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/SettingsSidebarNav.tsx#L281-L367) [_chat.settings.tsx L48–141](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/routes/_chat.settings.tsx#L48-L141)
- スコープの軸は project、machine、checkout。変更時は検索ハッシュをクリアする。Providers と Secrets は単一環境用。装置側のタブは General、Appearance、Chat、Diffs、SnapShots、Environments、Sharing & access、About。Sharing & access の環境選択はページ本文にある。タブの外枠、テキスト、フォーカスの既定は共通シェルと settings row を継承する。[_chat.settings.tsx L181–207](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/routes/_chat.settings.tsx#L181-L207) [SettingsScopeSentence.tsx L51–61](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/SettingsScopeSentence.tsx#L51-L61) [settingsLayout.tsx L528–576](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/settingsLayout.tsx#L528-L576)

<a id="SRC-S41"></a>

## SRC-S41 General

- `/settings/general`。Notifications、Sidebar、Confirmations、Display をスクロールする。変更トグルとセレクターは対応する行へ置く。ヘッダーの Restore device defaults は General のみ。狭幅ではそのラベルを読み上げ用に残し、アイコンを表示する。[SettingsPanels.tsx L846–914](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/SettingsPanels.tsx#L846-L914) [SettingsPanels.tsx L982–1013](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/SettingsPanels.tsx#L982-L1013) [SettingsPanels.tsx L1138–1206](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/SettingsPanels.tsx#L1138-L1206) [_chat.settings.tsx L31–44](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/routes/_chat.settings.tsx#L31-L44) [_chat.settings.tsx L154–171](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/routes/_chat.settings.tsx#L154-L171)

<a id="SRC-S42"></a>

## SRC-S42 Appearance

- `/settings/appearance`。ThemeLibrary、Interface、Typography を使う。ライト／ダーク・システム、テーマの選択とインポート、コントラスト／glass opacity、会話と HTML の幅、effort、数式、パネルアニメーションなどを変更する。幅や色の結果は [SRC-S08](01-workspace.md#SRC-S08) の CSS を参照。[AppearanceSettingsPanel.tsx L95–175](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/AppearanceSettingsPanel.tsx#L95-L175) [AppearanceSettingsPanel.tsx L177–396](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/AppearanceSettingsPanel.tsx#L177-L396) [AppearanceSettingsPanel.tsx L409–533](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/AppearanceSettingsPanel.tsx#L409-L533) [TypographySettings.tsx L119–216](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/TypographySettings.tsx#L119-L216)
- theme editor の浮動パネルにリサイズがある。viewport と 8px の外余白で寸法を制限する。下限は幅 280px、高さ 220px。ドラッグ時の上限は現在の左・上位置と viewport の残りで決まる。スライダーの棒は定義範囲に対する相対値で塗る。[AppearanceSettingsPanel.tsx L136–155](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/AppearanceSettingsPanel.tsx#L136-L155) [ThemeEditorPanel.tsx L283–307](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/ThemeEditorPanel.tsx#L283-L307) [ThemeEditorPanel.tsx L1095–1181](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/ThemeEditorPanel.tsx#L1095-L1181)

<a id="SRC-S43"></a>

## SRC-S43 Chat

- `/settings/chat`。Composer、Follow-ups、Subagents and side chats、Activity、Screen reader。送信キー、会話中の次メッセージ動作、作業状態などの表示を対象行から操作する。画面内の設定対象は機能の有効状態に従う。[SettingsPanels.tsx L1233–1275](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/SettingsPanels.tsx#L1233-L1275) [SettingsPanels.tsx L1354–1495](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/SettingsPanels.tsx#L1354-L1495)

<a id="SRC-S44"></a>

## SRC-S44 Diffs & pull requests

- `/settings/diffs`。Diffs と Pull requests のグループ。各行から差分の配置、色、表示・折り返し関連、PR リンクの扱いを設定する。差分の比較選択と出力自体は [SRC-S13](02-panels.md#SRC-S13)。[SettingsPanels.tsx L1700–1861](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/SettingsPanels.tsx#L1700-L1861)

<a id="SRC-S45"></a>

## SRC-S45 Keybindings

- `/settings/keybindings`。グループごとの command／現在の割当、追加、変更、ユーザー設定の操作。記録中はキー入力を捕捉する。条件付きバインディングには When の欄がある。既存キーのヒント tooltip は `max-w-72`（18rem）。[KeybindingsSettings.tsx L1084–1148](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/KeybindingsSettings.tsx#L1084-L1148) [KeybindingsSettings.tsx L1415–1497](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/KeybindingsSettings.tsx#L1415-L1497) [KeybindingsSettings.tsx L1688–1730](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/KeybindingsSettings.tsx#L1688-L1730)

<a id="SRC-S46"></a>

## SRC-S46 Voice

- `/settings/voice`。Input、Transcription、Dictionary、Cleanup の順にマイク、言語・モデル、辞書、後処理を設定する。実行環境が報告するハードウェアやモデルの情報で操作が変わる。モデル行の補助帯は `28rem` 未満で次行、`28rem` 以上で同一行側。選択欄の一部に `18rem` の上限を持つ。[VoiceSettingsPanel.tsx L839–906](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/VoiceSettingsPanel.tsx#L839-L906) [VoiceSettingsPanel.tsx L1237–1255](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/VoiceSettingsPanel.tsx#L1237-L1255) [VoiceSettingsPanel.tsx L1454–1570](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/VoiceSettingsPanel.tsx#L1454-L1570) [VoiceSettingsPanel.tsx L1805–1849](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/VoiceSettingsPanel.tsx#L1805-L1849)

<a id="SRC-S47"></a>

## SRC-S47 SnapShots

- `/settings/snap-shot`。キャプチャ入口、ショートカットの録音・変更、対応環境のセットアップを置く。実行可能な操作は desktop bridge とデバイス状況に従う。ショートカット録音のフォーカス・確定は専用ハンドラーを使う。[SnapShotSettings.tsx L84–142](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/SnapShotSettings.tsx#L84-L142) [SnapShotSettings.tsx L368–481](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/SnapShotSettings.tsx#L368-L481) [useSnapShotShortcutRecorder.tsx L1–152](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/useSnapShotShortcutRecorder.tsx#L1-L152)

<a id="SRC-S48"></a>

## SRC-S48 Providers

- `/settings/providers`。接続先なしは接続／再接続の案内、未登録または失われた instance は選択欄に説明を出す。対象 instance を URL で指定できる。読取権限だけの接続では Limited permissions を表示し、操作の可否を変える。[_chat.settings.providers.tsx L8–46](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/routes/_chat.settings.providers.tsx#L8-L46) [ProviderSettingsPanel.tsx L1085–1145](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/ProviderSettingsPanel.tsx#L1085-L1145)
- provider 一覧と選択中の詳細は `48rem` のコンテナ境界で 2 列になり、左列は `17rem`、右は可変。両方の本文がスクロールする。同じコンテナ条件で高さ `min(44rem, calc(100dvh - 11rem))`、最小 `32rem`。[ProviderSettingsPanel.tsx L239–240](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/ProviderSettingsPanel.tsx#L239-L240)行選択に追随して editor が変わり、Add provider・Refresh・Updates を権限と状態に応じて利用する。[ProviderSettingsPanel.tsx L1025–1146](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/ProviderSettingsPanel.tsx#L1025-L1146)

<a id="SRC-S49"></a>

## SRC-S49 Threads

- `/settings/threads`。New projects、Snooze、Usage limits、Auto-settle、Text generation。スコープや環境 capability によって表示される設定が変わる。Auto-settle の検索で対象が対応していないときは、選べる環境の案内へ進む。[SettingsPanels.tsx L1935–2018](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/SettingsPanels.tsx#L1935-L2018) [SettingsPanels.tsx L2058–2228](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/SettingsPanels.tsx#L2058-L2228) [_chat.settings.tsx L72–98](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/routes/_chat.settings.tsx#L72-L98)

<a id="SRC-S50"></a>

## SRC-S50 Browser

- `/settings/browser`。Agent access、Browsing、Recordings。リンク先、検索エンジン、ブラウザープロファイル、浮動表示、viewport、zoom、appearance、録画を管理する。Custom search URL はカスタム検索設定で使う。デバイスや scope によって行の利用可否が変わる。[IntegrationsSettings.tsx L764–832](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/IntegrationsSettings.tsx#L764-L832) [IntegrationsSettings.tsx L1109–1180](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/IntegrationsSettings.tsx#L1109-L1180) [IntegrationsSettings.tsx L1695–1735](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/IntegrationsSettings.tsx#L1695-L1735)

<a id="SRC-S51"></a>

## SRC-S51 Devices

- `/settings/devices`。端末ホスト、エージェントからの端末アクセス、利用可能な device source の登録と更新を扱う。ホスト・ソースの状態で設定行や操作が出る。実際の端末選択とストリームは [SRC-S17](02-panels.md#SRC-S17)。[_chat.settings.devices.tsx L1–6](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/routes/_chat.settings.devices.tsx#L1-L6) [IntegrationsSettings.tsx L878–895](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/IntegrationsSettings.tsx#L878-L895) [IntegrationsSettings.tsx L1738–1744](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/IntegrationsSettings.tsx#L1738-L1744) [DeviceSourcesSettings.tsx L616–651](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/DeviceSourcesSettings.tsx#L616-L651)

<a id="SRC-S52"></a>

## SRC-S52 Scheduled tasks

- `/settings/scheduled-tasks`。対象環境とプロジェクトの選択からタスク一覧へ進む。対象が利用できなければ Unavailable selection。編集ダイアログで環境、タイトル、宛先、workspace、prompt、条件付きの発火設定などを選択する。popup の幅上限は画面別に `42rem`、`36rem` の指定がある。[_chat.settings.scheduled-tasks.tsx L1–14](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/routes/_chat.settings.scheduled-tasks.tsx#L1-L14) [ScheduledTasksSettings.tsx L398–521](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/ScheduledTasksSettings.tsx#L398-L521) [ScheduledTasksSettings.tsx L976–1006](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/ScheduledTasksSettings.tsx#L976-L1006) [ScheduledTasksSettings.tsx L1256–1294](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/ScheduledTasksSettings.tsx#L1256-L1294) [ScheduledTasksSettings.tsx L1738–1939](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/ScheduledTasksSettings.tsx#L1738-L1939)

<a id="SRC-S53"></a>

## SRC-S53 Projects

- `/settings/projects`。選択前は project 指定の通知。project／checkout 選択後は名前、アイコン、checkout、アクションの設定。対象が消えた場合は unavailable の説明と、条件に応じて全環境を表示するボタン。枠は `min-h-0 flex-1`、内容の高さを親に合わせる。[ProjectsSettings.tsx L12–57](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/ProjectsSettings.tsx#L12-L57)

<a id="SRC-S54"></a>

## SRC-S54 Source control & issues

- `/settings/source-control`。サーバー環境、対象 forge／issue tracker、アカウント、host と連携関連の操作を scope に応じて並べる。情報の読込中は skeleton、対象が解決できない場合は環境選択側に進む。[SourceControlSettings.tsx L369–458](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/SourceControlSettings.tsx#L369-L458) [SourceControlSettings.tsx L461–512](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/SourceControlSettings.tsx#L461-L512) [SourceControlSettings.tsx L573–650](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/SourceControlSettings.tsx#L573-L650)

<a id="SRC-S55"></a>

## SRC-S55 Worktrees

- `/settings/worktrees`。Creation、Branches、Cleanup。Worktree のディレクトリ行は project または checkout scope で隠れる。リモート起点、詳細内の submodule、ブランチ命名、cleanup は各セクションへ置く。[WorktreesSettings.tsx L59–83](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/WorktreesSettings.tsx#L59-L83) [StorageSettings.tsx L598–672](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/StorageSettings.tsx#L598-L672)

<a id="SRC-S56"></a>

## SRC-S56 Environments

- `/settings/connections`。desktop bridge があると This app を表示する。環境一覧には対応幅で Map／List の切替があり、保存済み環境の追加、経路、接続状態などを扱う。クラウドの追加操作は公開クラウド構成の有無で変わる。[ConnectionsSettings.tsx L1825–1926](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/ConnectionsSettings.tsx#L1825-L1926)

<a id="SRC-S57"></a>

## SRC-S57 Sharing & access

- `/settings/access`。ページ側で対象環境を選ぶ。候補環境が複数あれば幅最大 `18rem` の picker、選択不能なら案内。接続アクセス・authorized clients などの詳細は scope に従う。authorized clients の展開リストは最大 `22.5rem`。[ConnectionsSettings.tsx L180–229](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/ConnectionsSettings.tsx#L180-L229) [ConnectionsSettings.tsx L1297–1316](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/ConnectionsSettings.tsx#L1297-L1316) [ConnectionsSettings.tsx L1451–1499](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/ConnectionsSettings.tsx#L1451-L1499) [ConnectionsSettings.tsx L1815–1826](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/ConnectionsSettings.tsx#L1815-L1826)

<a id="SRC-S58"></a>

## SRC-S58 Secrets

- `/settings/secrets`。対応環境があるとナビに表示。全環境の報告が揃って非対応なら General へ置換する。対象環境・アクセスに応じて説明または secret provider の設定を表示し、名前等の長いラベルは truncate。[settingsSearch.ts L180–190](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/settingsSearch.ts#L180-L190) [_chat.settings.secrets.tsx L7–19](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/routes/_chat.settings.secrets.tsx#L7-L19) [SecretsSettings.tsx L38–78](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/SecretsSettings.tsx#L38-L78) [SecretsSettings.tsx L109–191](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/SecretsSettings.tsx#L109-L191)

<a id="SRC-S59"></a>

## SRC-S59 Maintenance

- `/settings/maintenance`。Updates、Background activity、クリーンアップ・artifacts、Diagnostics への入口。アップデートのトラックや依存環境、ストレージ操作の入口は capability と scope による。[SettingsPanels.tsx L2379–2525](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/SettingsPanels.tsx#L2379-L2525) [StorageSettings.tsx L875–968](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/StorageSettings.tsx#L875-L968)

<a id="SRC-S60"></a>

## SRC-S60 Labs

- `/settings/labs`。Beta グループ内で sidebar、guest links、linked environments、workflows、prompt suggestions、端末ホスト、worktree、agent feedback の設定行を扱う。行を表示する条件と、実際に機能を使うための対応環境はそれぞれ設定部品側で判定する。[LabsSettingsPanel.tsx L36–60](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/LabsSettingsPanel.tsx#L36-L60) [LabsSettingsPanel.tsx L110–232](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/LabsSettingsPanel.tsx#L110-L232) [LabsSettingsPanel.tsx L293–448](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/LabsSettingsPanel.tsx#L293-L448)

<a id="SRC-S61"></a>

## SRC-S61 About

- `/settings/about`。App を開くと組織・バージョンなど、Legal で文書やライセンスへの入口を表示する。バージョン関連の表示は現在の実行環境で変わる。ライセンス詳細は About をアクティブ表示したまま移る。[SettingsPanels.tsx L2526–2618](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/SettingsPanels.tsx#L2526-L2618) [SettingsSidebarNav.tsx L120–124](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/SettingsSidebarNav.tsx#L120-L124)

<a id="SRC-S62"></a>

## SRC-S62 Archive

- `/settings/archived`。読込中／空の表示か、対象アーカイブの行を表示する。scope に応じてグループ化し、行から対象のスレッド操作へ進む。本文は縦スクロールでき、各グループが件数に応じて増える。[ArchivedThreadsPanel.tsx L265–373](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/ArchivedThreadsPanel.tsx#L265-L373)

<a id="SRC-S63"></a>

## SRC-S63 Diagnostics

- `/settings/diagnostics`。Maintenance 配下の詳細画面。対象環境を変えると内容側が再初期化される。環境・テレメトリー状態に応じて失敗、遅い span、ログ、集計を表示する。詳細 popup の一部は高さ最大 `min(64vh,44rem)`。表の失敗メッセージ欄に 360px の上限指定。[_chat.settings.tsx L143–152](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/routes/_chat.settings.tsx#L143-L152) [SettingsSidebarNav.tsx L120–124](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/SettingsSidebarNav.tsx#L120-L124) [DiagnosticsSettings.tsx L350–382](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/DiagnosticsSettings.tsx#L350-L382) [DiagnosticsSettings.tsx L1245–1336](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/DiagnosticsSettings.tsx#L1245-L1336)

<a id="SRC-S64"></a>

## SRC-S64 Open-source licenses と互換ルート

- `/settings/open-source-licenses` は About の詳細で、同じ本文スクロール領域に third-party notices を出す。`/settings/integrations`、`/settings/storage`、`/settings/beta` は順に Browser、Maintenance、Labs への互換入口。旧リンクに指定したハッシュが移動済みなら該当タブを優先し、ハッシュと検索条件を引き継いで履歴を置換する。[_chat.settings.open-source-licenses.tsx L1–7](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/routes/_chat.settings.open-source-licenses.tsx#L1-L7) [OpenSourceLicenses.tsx L265–318](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/OpenSourceLicenses.tsx#L265-L318) [SettingsSidebarNav.tsx L120–124](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/SettingsSidebarNav.tsx#L120-L124) [settingsSearch.ts L1560–1588](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/components/settings/settingsSearch.ts#L1560-L1588) [_chat.settings.tsx L209–219](https://github.com/pingdotgg/t3code/blob/ca81b7b97a1c4b91e5ac25768d0f6629f37732fd/apps/web/src/routes/_chat.settings.tsx#L209-L219)
