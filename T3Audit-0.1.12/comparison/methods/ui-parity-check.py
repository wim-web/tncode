#!/usr/bin/env python3
"""Generate the UI comparison and validate it and the 61 authored screen rows."""

import argparse
import json
import re
import subprocess
from collections import Counter, defaultdict
from functools import cache
from pathlib import Path

AUDIT = Path(__file__).resolve().parents[2]
COMPARISON = AUDIT / "comparison"
PI = AUDIT.parent / "PiWorkspace"
T3 = AUDIT / ".source"
COMMIT = "ca81b7b97a1c4b91e5ac25768d0f6629f37732fd"
NATIVE_FILES = {
    "A": "PiWorkspaceApp", "C": "SourceControlView", "E": "PiProcess",
    "G": "GitWorkspace", "L": "ThreadLocationView", "M": "WorkspaceModel",
    "P": "ProjectFolderView", "S": "Workspace", "T": "ThreadTerminal", "W": "WorkspaceView",
}
UI_COLUMNS = "id status verification swift_source difference acceptance".split()
SCREEN_COLUMNS = (
    "state_id screen_intent_ja reference source_commit source_locations "
    "status verification native_counterpart swift_source difference acceptance"
).split()
STATUSES = {"同等候補", "部分", "未対応", "構成差", "対象外", "未判定"}
VERIFICATION = "ソース確認"

RULES = """\
1 019-023 052-055 059-065 161 188 103 1213	未対応	A:68 W:151	固定ショートカットとローカルスレッド検索を提供する。コマンド登録、履歴操作、フォーカス巡回、横断検索のシェルは持たない。	アプリのメニューとスレッド一覧を開き、指定のコマンドや遷移先を同じ入口から利用できるか確認する。
002-012 706-707 709-714 718-722 724-726	未対応	W:349 W:420	右側はローカル Git の Changes。ブラウザーのホスト・URL・ビューポート・プレビュー、サーバーカードと Mini Player は持たない。	ローカル HTTP ページを用意し、右側の入口で対象の Web 表示または制御を探す。
013-014 057 094-097 152 510 733	未対応	P:20 M:102 C:36	実在のローカルフォルダーを登録する。別マシンへの移送、リモートの clone/publish、ファイルコピー設定はない。	既存フォルダーを追加した後、接続先・clone 方式・除外ファイル・公開ホストのうち指定の操作が現れるか確認する。
015 018 090-093 108-145 153-156 173 183-185 187 210-212 229-230 257-270 308 378 380 405 416 449 451 708 715-717 1202-1203 1205 1208 1212	構成差	W:55 W:60 W:349	描画・状態・委譲の構成要素を親画面で評価する。SwiftUI に元の React 部品の公開操作はない。	使用先を特定して親画面を開き、指定された見た目・状態の役割と操作が別画面や別コマンドとして数えられるか確認する。
016-017 075	構成差	W:68 W:95 P:42	SwiftUI のシート・確認ダイアログ・Cancel。Web の route modal、背景クリック、フォーカス復帰ルールを共有しない。	フォルダーシートと確認ダイアログをキーボードで開閉し、確定・取消とその後のフォーカスをそれぞれ確認する。
025 1211 1214	部分	W:60 W:113 W:220	左は固定範囲の HSplitView と SwiftUI のスレッド一覧。T3 の sidebar mode、独自の resize/restore や Web フォーカス制御はない。	左境界を動かし、一覧を開いた状態で指定された折りたたみ・復帰・リスト操作を試す。
026-027 029-030 032-033 213	部分	C:80 L:27 L:43 M:247	ローカルブランチの切替と送信前の worktree 指定を別の UI で提供する。リモート ref、環境選択、自動バランスや横断検索を含まない。	Git プロジェクトで現在ブランチと別のローカル base を選び、指定された ref 検索または環境／運用モードが選べるか確認する。
035-049 235-238 321-323 333-334 339-354	未対応	W:582 E:4	assistant の表示は inline Markdown。対象コンポーネント固有のノード操作、メディア・成果物や外部連携は提供しない。	対応する Markdown またはメディアを返し、本文と独立した指定のインライン操作、ビューアーまたは成果物が現れるか確認する。
050	部分	W:349 W:394 W:454 W:597 E:11	同じローカル窓にヘッダー・会話・入力・Terminal・Changes。別環境、右パネルタブ、承認と添付の状態は存在しない。	新規、進行中、完了、アーカイブの順で対象コンテキストを表示し、該当する操作の入口と処理結果を確認する。
051 228 246 442-443 455-456 461 463-470 472-475 499-505	未対応	W:558 W:628 M:425 E:11	本文と一時的なツール名・worktree 準備表示に限る。独立した実行記録、出力ビューアー、実行段階の折りたたみや再操作はない。	ツールまたは worktree の動作を伴う会話を開き、指定のログ、カード、展開操作が本文と別に出るか確認する。
056	部分	P:20 P:42 P:62 M:102	既存の絶対パスを入力するか Browse で選んで確定する。T3 パレットの相対パス解決と未作成フォルダーの作成、環境別の追加に対応しない。新規登録後は通常 New Thread を別に押す。	Browse とパス入力で既存フォルダーを登録する。空白、相対パス、存在しない絶対パスを別々に試し、登録後に画面が自動で下書きへ移るか確認する。
066 247 285-286 300	部分	W:650 M:219 S:31	ツール対応モデルだけに表示し、Read files／Shell and edits をプロジェクトごとに保存する。T3 の runtime mode、権限種類、選択可否・focus の分岐とは異なる。	ツール対応と非対応を比較し、モードの選択、同じプロジェクトへの反映と指定された権限の選択肢を確認する。
067-072 080-082 186 222-227 275-280 311-312 328 391-392 397 482-483 485-486 533-534 536-537 539-541	未対応	W:641 W:649 E:51	文字列の編集と送信。Tiptap の chip、mention、引用、添付・context と入力内コマンド候補を構成しない。	新規入力で指定された参照・添付・chip を挿入し、候補や編集操作が提示されるか確認する。
074	部分	W:641 W:680 M:66	縦方向のプレーンな TextField と Command-Return。リッチなノード編集、コンテキスト候補、IME とキーバインドに応じた送信制御は実装していない。	複数行を入力して送信し、変換中文字列・Enter・Command-Return と指定されたノードの挿入結果を確認する。
076-079 089 104-107 190 216-221 335-338 542-543 647-651 730-732 1487	未対応	A:50 W:349 M:384	ローカルの Pi helper を起動するクライアント。接続相手の pairing・SSH 認証、Hosted／guest／linked thread の表示を持たない。	ローカル会話を開き、指定された別環境、接続状態、資格情報や共有による画面への入口があるか確認する。
083 171 179-180 1220 1226-1228 1232	未対応	W:113 W:220 W:284 W:329	ローカルの単一行に操作する。保存ビュー、複数選択、Snooze、行ドラッグ・Undo と独立 draft の操作を持たない。	複数の会話または未送信の会話を用意し、指定の棚、保存ビュー、複数行操作が使えるか確認する。
084	対象外	A:50 E:11	T3 開発用 DevReplayHost。Pi Workspace の配布機能と別の開発条件。	通常の状態で開き、開発専用の replay 入口は配布の比較から除外できるか確認する。
085-087 575-576	未対応	C:164 C:188	変更ファイルのパス表示とパッチのテキスト選択を持つ。Diff 固有のパスコピー、折りたたみ、行範囲注釈を実装していない。	差分を持つファイルを選び、パス専用コピー、ハンクやファイルの開閉、1行の注釈のうち対象操作を探す。
088 578	部分	C:99 C:164 C:188 G:88	選択ファイルまたは全体の Staged／Unstaged を縦横スクロールする。単一 checkout のプレーンなパッチで、履歴・ターン・ref 比較、注釈・diff tree はない。	部分ステージ済みファイルを選び、両モードのパッチを比べる。指定の比較先、ツリー展開または行操作が現れるか確認する。
098-100	部分	W:420 C:80 C:130 C:217 G:149	Changes でローカルブランチ、ファイル単位 stage／unstage とローカル commit。公開、PR、同期や外部 forge に関わる操作は実装していない。	一つのファイルを修正し Changes でパッチ、stage、commit を確認する。指定の Git 操作がメニューにあるか調べる。
101-102	対象外	A:50 W:372	T3 の GitHub Star の案内タイミングとその起動後待機。固定契約の対象外枠。	通常の配布フローで Star 案内の経路を参照し、ローカル作業開始の必須条件とは独立して記録する。
146 965-985	未対応	A:68 W:680	メニューと composer に固定割当がある。構成警告やショートカット追加、When 条件、競合編集を扱う UI はない。	固定キーを実行し、設定に割当表示・上書き・条件式・競合の指定機能があるか確認する。
147-148 182 904 907-908 997-1004 1007 1072-1077 1118-1123	未対応	A:99 M:229	モデル設定は単一のローカルストア。組織ポリシー、アクセス scope、接続元とルート別の編集はない。	設定を開き、指定された環境・ポリシー・接続経路で制御項目の可否を変えられるか確認する。
149 320	部分	W:372 W:385 W:454 P:20 M:166	空時の Add Project とプロジェクト内の New thread を提供する。scratch と下書き内の検索式プロジェクト選択はない。	空のストアからフォルダーを追加して下書きを開く。対象の選択、特にプロジェクトなしで開始できるか確認する。
150 209 244	部分	W:429 W:514 W:524 W:543 T:18	スレッドとパスに対応する下部 SwiftTerm。Hide で維持、Close で破棄。高さ固定で、ターミナルタブ・分割・行の常設端末管理はない。	端末で作業先と出力を確認し、非表示、再表示、終了で状態を比較する。対象のタブ・分割・端末レイアウトも探す。
151 207-208	未対応	W:524 W:543 T:18	一つのスレッド／パスで一つの drawer。右パネルの session 切替、タブ側の terminal panel、複数 pane の分割はない。	同じスレッドの端末を開き、T3 の分割・グループ選択や右側への移動ができるか確認する。
157 158 214-215 241-242 429-433 727-729	未対応	W:318 W:476 L:27 M:318	ローカルの単一フォルダーと worktree は扱う。プロジェクト pin、スクリプト管理、複数 repo 選択、承認付きレイアウトと Git の復元確認はない。	プロジェクトメニュー、作業場所と Thread Details を開き、指定の構成項目や専用操作の有無を確認する。
159 172 174-175 544-545 881-882 1116 1188-1189 1210 1223 1233-1238	未対応	A:99 W:206	設定はモデル用。更新トラック、サーバー・ツール・プロバイダー更新、通知、リリースノートの操作はない。	設定とサイドバーを開き、対象の更新確認、適用、トラック変更または完了通知があるか確認する。
160 191-196 232 239 408-410 412-415 484 535 538 652-673 734-853 955 1062-1063 1134-1142 1177 1489	未対応	W:349 W:476 C:36 C:217	ローカル Git の変更とコミットに限る。PR・Issue の専用メタデータ、forge 認証、閲覧、投稿、チェック、レビュー、関連付けは実装していない。	既存の PR または Issue を持つ checkout を開き、指定の表示・フォーム・操作へアクセスできる項目があるか確認する。
162-170 243 373 387 723	未対応	W:349 W:420 W:438	Changes は独立のネイティブ split、Thread Details はポップオーバー。右ペインの共通タブ、ソート・追加・最大化・Web シートは持たない。	右側とヘッダーを表示し、対象のタブや操作、ウィンドウ幅による右側の切替を確認する。
176 198-200 434	構成差	W:284 W:300 W:625	ローカルの行選択と入力下の phase 表記を描画。T3 の行内バッジの内容や status 委譲は個別機能で評価する。	複数スレッドの選択と実行を行い、該当する役割でどのラベルや操作が現れるか確認する。
177	部分	W:248 W:318 M:102	グループ化されたプロジェクト行の context menu に新規、改名、再リンク、除去。Copy path、Pin project、設定リンクはない。	グループ表示のプロジェクトを右クリックし、New Thread と指定メニュー項目をそれぞれ確認する。
178	部分	W:113 W:151 W:220 W:284	作成、検索、単一プロジェクト絞り込み、pin/settled/archived の棚。環境をまたぐ選択、行のドラッグ、保存ビューや複数選択はない。	複数プロジェクトの会話を検索して一つ開き、対象の棚と操作を探す。
181 1230	部分	W:284 W:329 M:203 M:211	単一スレッドの改名、Pin、Settle、Archive／Restore。T3 の通知、Snooze、Delete、リンク・PR・別環境のメニューを含まない。	未アーカイブとアーカイブで同じ行のメニューを開き、指定のラベルが表示される条件と操作後の棚を確認する。
189 273-274 284 302-304 319 324-326 381-384 398-402 417 448 480-481 509 511-512	未対応	W:597 W:625 M:425 E:11	エラーと簡易 phase をローカルに表示する。元の独立した確認、質問、保留、セッション、使用量や活動バナーの操作はない。	対象の待機・実行・エラー条件を作り、指定バナーや選択肢が現在の状態説明とは別に表示されるか確認する。
201-202 205	未対応	W:524 T:18 T:69	SwiftTerm による文字入出力。T3 の選択 context menu、チャットへ追加と専用ジャンプの操作は Pi Workspace 側で構成していない。	端末出力を選択して右クリックし、対象となる項目と Composer への受け渡しの有無を確認する。
231 283 287-288 307 379	部分	W:641 W:650 W:663 W:672 A:103 M:66	プレーン入力、単一のアプリ共通モデルの設定入口、プロジェクト許可、Send／Stop。T3 の添付、モデルピッカー、Queue／Steer 等の条件分岐を含まない。	アイドルと実行中で入力メニューを開き、モデルの編集先、送信と停止、指定された条件付き操作を確認する。
233-234	部分	W:394 W:408 W:420 W:438	プロジェクトとスレッドのメニュー、Changes／Terminal／Details。親スレッドの案内、Project settings ルート、共有、インラインタイトル編集はない。	通常スレッドのヘッダーを開き、該当メニュー項目と対象画面への遷移を確認する。
240 546-574 928 956 1125-1126	未対応	W:349 W:524 A:99 T:73	macOS 上のローカルシェルを提供する。物理端末・シミュレーターの接続、映像、操作やホスト管理を持たない。	デバイスが接続可能な条件を用意し、指定のホスト、画面や遠隔操作の入口を確認する。
245 369-370 376-377 388-390 403 422-428 438-440 462 491-496	未対応	W:394 W:558 E:11	ローカルの独立会話を表示する。子スレッド、委譲・自動化、計画アクション、会話から発行する Secret 応答はない。	親子や計画、Secret を含む想定状態で対象の専用行・ボタン・入力欄が表示されるか確認する。
248-256 291 393-396 452-453 507-508 580-637 640-646 684-688	未対応	W:487 W:582 W:641 P:54 C:188	フォルダー追加、Finder、本文と Git パッチ表示には対応する。添付ファイル・電子文書、画像、音声、動画、ツリー、本文の編集とプレビューは持たない。	対象ファイルを用意して入力、フォルダーメニューと Changes を開き、指定された preview・編集・追加操作の有無を確認する。
271-272 289-290 317-318	未対応	W:597 W:625	簡易エラーと状態ラベル。Composer のバナーの開閉、保留解除、用途制限と新規セッションの個別操作はない。	対象の状態でラベルとは別にバナー操作、閉じる、復元が提示されるか確認する。
281-282 638-639 945-946 1090 1104 1206-1207 1215 1225	構成差	W:220 W:438 W:650 A:99	SwiftUI の Button、Menu、Label、フォーム行を呼び出し元に直接組み込む。汎用の部品構成は独立したアプリ機能から区別する。	対象部品の利用元と対応する Swift の画面を表示し、同じ役割が実際の操作を受けるか確認する。
292-299 301 363-368 476-478	未対応	A:103 A:112 W:663	プロバイダー Picker とモデルIDの直接入力。モデル候補リスト、effort・速度・特性や複数モデル編集を持たない。	ツール対応モデル設定を開き、指定のモデル候補、effort、速度または trait を設定できるか確認する。
305	部分	W:672 M:369	実行中の停止と停止待ち中の再押下抑止は対応。T3 の条件付き pointer focus 保持と権限判定は Swift のボタンにない。	応答が続くターンで Stop を押し、要求送信後に停止待ちの再押下ができず、終了後に入力が戻ることを確認する。
306	部分	W:672 M:369	停止は可能だが SwiftUI の入力カードに一つ。狭幅の折りたたみ専用ボタンはない。	最小幅と通常幅で実行を始め、停止ボタンの表示と停止処理を確認する。
309-310 327 497-498 705 897-898 1008-1011 1143 1192-1200 1490-1491	未対応	W:641 A:99	専用マイク、文字起こしの表示・設定と入力への連携は持たない。	指定の音声入力やマイクの条件で、専用の操作と入力結果を確認する。
355 441	構成差	W:582 W:590	メッセージ本文は選択可能。T3 の行にあるコピー専用ボタンやクリック処理はない。	本文を選択して標準コピーを試し、指定のコピー専用ボタンの有無を確認する。
356-357 435-437 454 457 460	部分	W:558 W:582 E:4	ローカルのユーザー／assistant 本文とストリーミングを表示する。行ごとの添付、履歴折りたたみ、返信・分岐、日時ボタンなどを持たない。	ユーザーと assistant の両方がある長い会話で、該当行の表示と指定された操作を確認する。
358-359 419-421 444-447 854-856	未対応	W:44 W:151 W:558 W:577	サイドバーの題名検索と transcript の自動末尾追従。本文検索、minimap、手動の末尾ジャンプ、ファイル横断検索はない。	長い会話と別ファイルを用意し、指定の検索・強調・選択・移動操作が使えるか確認する。
360 471 506	部分	W:626 L:38 M:318 M:337	新規 worktree の最初の送信で作成を進め、進捗ラベルとエラーを表示する。作業スクリプトやログのカード、取消・作業先変更を持たない。	新規 worktree を指定して送信し準備中、成功、作成失敗でラベルと指定された操作を確認する。
371	部分	W:476 W:487	対象フォルダーを Finder へ渡す。エディターの列挙、既定切替、SSH 越しの起動はない。	スレッドのパスで Show in Finder を実行し、別エディターへの選択肢があるか確認する。
372 374	部分	W:394 W:420 W:429 W:438	ヘッダーに3つのトグル。ポップオーバー、Changes、Terminal を別々に制御し、タブ付き右パネル全体は扱わない。	スレッドを開き各トグルを押し、指定の領域が開閉されるか確認する。
375	構成差	A:50 A:67 W:394	macOS の標準ウィンドウを使用し、T3 renderer の titlebar overlay と独自最大化制御を置かない。	ネイティブタイトルバーでサイズ変更を試し、対象のカスタムウィンドウ操作の表示を確認する。
385-386	部分	W:558 W:607 M:203	ローカルアーカイブで会話本文を表示し入力を Restore Thread に置換する。linked/guest の読み取り専用権限と共有データはない。	アーカイブしたスレッドで履歴を読み、Restore Thread を押して入力が戻るか確認する。
404 406-407 411	部分	W:438 W:476 W:487 W:495	Thread Details は固定幅ポップオーバー。場所、Finder、モデルを表示する。inline 配置、密度切替、開閉の Web フォーカス処理や拡張項目はない。	窓幅を変えてポップオーバーを開き、対象のラベル、配置と利用可能な操作を確かめる。
490	未対応	W:558 W:628 E:11	ツール名だけを一時表示する。個別の tool output や大型内容・画像の取得と展開はない。	読み取りツールが返す結果を使い、完了後に対象の内容を開けるか確認する。
513-532 674-683 863-864 892-895 899-903 905-906 929-944 1012-1014 1488	未対応	A:50 A:99 M:384	固定フォームの API キー設定とローカルプロセスを使う。T3 アカウント、T3 Connect、トンネル、モバイルクライアントや環境グラフを管理しない。	設定を開き、対象のサインイン、機械間の共有、移動、認可の入口があるか確認する。
689 1477-1479 1481	未対応	W:372 W:597 M:384	起動・接続のエラー文と閉じた worker の再接続がある。Web ルートの復旧、初回ハイドレーション、Reload、詳細 Copy の画面はない。	起動エラーと worker 切断を分けて作り、指定された再試行、詳細または復旧先の表示を確認する。
690 692-693 1480	部分	W:372 W:454 P:20 A:99 M:166	初回にも通常のワークスペースを表示。モデル設定とフォルダー追加を手動実行する。Welcome の agent 検出・自動下書き・候補インポートはない。	ストアを空にしてアプリを開き、対象の初回状態、モデル設定とローカルフォルダーの登録を確認する。
691 694-704	未対応	W:372 A:99	初回は標準の空ホーム。Welcome 手順の通知、電話、既存履歴取り込み、CLI 導入、権限チェックはない。	空のストアから起動し、対象の初回設定操作と表示の有無を確認する。
857 1016-1019 1105 1117	未対応	A:50 A:99	専用のバージョン詳細、法務、ライセンス一覧を Swift のアプリ設定で定義しない。macOS 標準メニューとは別の比較。	アプリメニューと設定で対象のバージョンや法務文書を探す。
858-862 865-867 909 1036-1039 1041-1048 1054-1061 1151-1155 1482	未対応	A:99 A:103 S:4	固定の3プロバイダーで設定一つ。動的な instance、モデルの追加ウィザード、環境・project override、CLI 管理・更新はない。	Model Settings を開き、指定の instance やモデル一覧、複数環境への導入または個別状態更新ができるか確認する。
870 947 1020 1102-1103 1156-1176 1179-1187	未対応	W:55 W:571 W:641 A:99	システム外観と固定の書体・幅。Editor、テーマのプレビュー・入出力、Typography の個別設定はない。	システム配色を変更して比較し、指定のテーマ・フォント・プレビューをアプリ内で変更できるか確認する。
871-873	部分	W:163 W:237 W:343 M:203	サイドバーの Show Archive と Restore Thread。専用設定ページ、環境別表示、Delete は持たない。	複数のアーカイブを表示、検索して一件復元し、指定のメニュー項目・空表示があるか確認する。
874-880 988-990 1092-1099	未対応	A:122 M:229 M:425	Keychain に保存するのは現在のモデル用 API キー。共有資格、Secret provider の追加、権限・リンク・供給元選択はない。	モデル設定で保存キーの状態を確認し、対象となる外部サービスの登録／失効を扱えるか調べる。
883 1024-1025 1034 1144-1148 1201	未対応	L:27 M:318 S:179	ローカル worktree を送信時に作成し専用ストアに保存。作成・命名の全体設定や remote 起点、サブモジュール、保持と cleanup はない。	Thread workspace で branch を編集し、指定の全体設定が Model Settings にあるか確認する。
884-890 948-954 957-959	未対応	W:349 A:99	統合ブラウザーの設定とインポート手順を持たない。	設定で指定されたブラウザー構成、権限・プロファイル・表示の変更手順の有無を確認する。
891 1127-1129 1209	未対応	A:68 W:641	キャプチャ権限の案内、SnapShots の操作割当と録音を追加しない。	設定とメニューで指定のキャプチャ手順やショートカットが使えるか確認する。
910-911 918-927 1021 1064-1071 1149-1150	未対応	A:99 W:597 M:425	スレッドにエラーと簡単な状態を表示する。診断・ストレージ・プロセスやテレメトリーを扱う設定と集計はない。	失敗したローカル会話の後、指定の診断情報・保管量・プロセス操作の一覧が開けるか確認する。
912-917 994	未対応	A:99 W:524 T:73	端末はローカルシェル用。デバイスソースと host の設定を持たない。	端末を開き、指定の機器の設定やホスト接続の入口を探す。
960 1078-1089 1483	未対応	A:99 W:329	スレッドの設定に Scheduled tasks・Webhook 画面を提供しない。	指定の定期実行、対象選択、Webhook または履歴の操作を探す。
961-964	未対応	A:99 C:36	Workspace の Git 操作はローカルのみ。Issue tracker のアカウント、プロジェクト束縛や権限を管理しない。	既存の issue tracker を対象に、指定の設定を登録できる欄があるか確認する。
986-987 991-993 995-996	未対応	A:99 W:7 W:220	グループ化は通常設定として配置。段階的な Labs のトグルや実験条件を持たない。	対象機能を有効にした時だけ関連する表示が現れる設定があるか確認する。
1015	未対応	W:206 A:99	アプリ内通知の設定画面を持たない。	アプリ設定で対象の通知を個別に更新できるか確認する。
1022-1023 1026-1032	未対応	W:318 W:396 P:20	ローカルプロジェクトの名前・登録フォルダーを変更できる。アクション、アイコン、favicon、複数 checkout を扱う設定 UI はない。	登録したプロジェクトを選択し、指定のアイコン・アクション・checkout 操作を探す。
1033 1035	部分	W:95 W:318 W:396 P:20 M:102	プロジェクトメニューに名前変更、再リンク、除去。設定ページ、複数 checkout と全環境スコープはない。	プロジェクト名を変更して再リンクし、指定の設定項目・スコープ選択の有無を確認する。
1040 1049 1091	部分	A:122 A:142 M:224 M:229	伏字の API キー入力と Keychain への保存、置換、条件付き削除。T3 の OAuth、サインイン状態、外部 secret 参照は含まない。	テスト用の設定でキーを保存し、伏字・置換・削除の表示と指定の認証方法を確認する。
1050-1053	部分	A:103 A:112 A:114 A:142 S:37	固定の Picker、モデルID と Local の URL／context window／ツール可否。スキーマで生成した動的フォーム、継承・各項目の clear 操作はない。	Local と他 provider を切り替え、指定の入力が利用できる条件と無効値の保存結果を確認する。
1100-1101 1124 1484-1486	未対応	A:77 A:99 W:68	Model Settings の単一シート。設定検索、カテゴリ遷移、スコープ継承や device defaults の復元はない。	ショートカットで設定を開き、検索・継承・復元・対象のタブ操作を確認する。
1106 1114-1115 1130-1133 1178	未対応	W:329 M:349 A:99	行の手動 Settle と初回本文による命名。Snooze、日数、圧縮や名前生成の設定はない。	手動 Settle の操作後に指定の日数、既定値、テンプレートを設定できるか確認する。
1107	部分	W:7 W:183 W:220 A:99	プロジェクトのグループ化は独立したサイドバーメニュー。他の独立した General 設定と全体復元はない。	Thread filters を切り替えて再起動し、設定から指定される項目や既定値復元が使えるか確認する。
1108-1113	未対応	W:641 W:680 C:188 C:240 A:99	送信動作と Git パッチの見た目は固定。Chat・Diff 設定の指定項目や読み上げ、配色、折り返しを変更できない。	設定、会話、Changes を開き、指定の切替や既定値設定が表示されるか確認する。
1216	部分	W:206 A:77	Settings の入口はある。戻る、PR・Issue・Usage 一覧へ移るユーティリティメニューはない。	サイドバー下部を開き、Settings と指定の画面への入口を確かめる。
1217-1218	部分	W:284 W:454 M:166	未送信の会話も保存済みの通常行。独立した Drafts ブロックや未送信専用アクションを持たない。	送信前の会話を作り、対象行と専用セクション、操作の有無を確認する。
1219	未対応	W:113 P:54	プロジェクトは入力シートと folder importer で追加する。サイドバーへ落とす経路はない。	Finder のフォルダーをサイドバーへドラッグし、登録後に同じ登録結果が出るか確認する。
1221-1222	部分	W:190 W:248 W:267	グループ化したプロジェクトの開閉、新規作成、コンテキストメニュー。独自のソート／ドラッグと環境別グループの行状態はない。	Group by Project を有効にし、ヘッダーを閉じて開き、対象のボタンまたはメニューを確認する。
1224 1231	部分	W:44 W:151 W:284 M:184	テキストでタイトル・プロジェクト名を絞り検索結果を選択する。クリア専用ボタン、候補のキーボード強調やドラッグはない。	題名の一部を入力し対象を選ぶ。指定のクリア、ハイライト、選択操作で結果がどう変わるか確認する。
1229	部分	W:95 W:329 W:723 M:197	名前の編集は行内で行わず Rename alert を使う。前後空白を除去し、空白のみは保存しない。	行の名前を変更し、取消、空白名、前後に空白のある名前を各1回確定する。
1438-1457 868 1005-1006 1190-1191	未対応	W:476 A:99 E:11	モデル名・一時的な実行状態を表示する。使用量集計、上限、アカウントの信用枠、料金テーブルや期間別グラフを持たない。	数回実行した後、対象の集計・フィルター・可視化と操作の有無を確認する。
1458-1476	未対応	W:329 W:476 E:11	会話作成と独立したワークフロー定義、手順、確認カード、run 履歴と編集はない。	プロジェクトとスレッドのメニューで、指定の Workflow を開いて設定または実行できるか確認する。
329-332	未対応	W:349 W:408 W:641	スレッドの共有リンクとゲスト権限、ゲスト参加者、および未配置メッセージを扱う UI はない。	スレッドのメニューと入力を開き、対象の共有、指標、ゲストのメッセージ操作があるか確認する。
361-362 450 458-459	未対応	W:558 W:582 E:4	本文の表示と文字選択のみ。ターン折りたたみ、リトライ・取消、メッセージ意図表示と区切り操作はない。	履歴に複数のターンを作り、対象の折りたたみ、差し戻し、区切りが表示・操作できるか確認する。
479	未対応	W:454 W:641	新規ローカル会話の入力画面。外部の Issue 等を取り込むトリアージ専用の下書きではない。	外部項目を開いてトリアージの初期コンテキストや対象の下書き操作が表示されるか確認する。
487-489	未対応	W:558 W:628 E:11	実行中のツール名を入力下に表示。ツール引数、結果遅延取得、結果画像は専用表示しない。	ツールを実行する会話を開き、対応する引数、出力、画像を履歴から調べられるか確認する。
577	部分	C:44 C:188 C:273 G:115	赤いパッチエラーとパネル全体の Refresh、256 KiB 超の切り捨てを示す末尾文。ファイル単位の再試行または部分プレビュー専用のステータスボタンはない。	パッチエラーあるいは256 KiB超の差分を用意し、エラー、再試行の範囲、切り捨て表示を確認する。
869 896 1204	未対応	A:99 A:114 M:229	ローカルモデルの専用入力だけを提供。T3 CLI、組織ポリシーや一般の詳細設定を管理する項目はない。	Model Settings を開き、指定された CLI 構成、詳細設定または組織ポリシーの操作があるか確認する。
1239-1247 1308-1320 1384-1390	構成差	W:68 W:72 W:88 W:95 P:42	SwiftUI の sheet／alert／確認ダイアログが実画面を担当する。元の Base UI backdrop、viewport、portal と close ラッパーに独立した SwiftUI 機能は割り当てない。	プロジェクトの追加・改名を表示し、指定のタイトル、確定・Cancel とフォーカスを親フォームで確認する。
1248-1251 1323-1328	構成差	W:372 W:597 C:60	空のホーム、エラー、Git なし等を用途に応じた SwiftUI の Text や Button で描画する。Web の共通状態部品と同一の振る舞いは主張しない。	空ストアか Git なしのフォルダー、または切断時に画面を開き、指定の空・エラー表示と実際の回復操作を確認する。
1252-1263 1280-1307 1340	未対応	A:68 W:151 W:220 W:641 A:103	SwiftUI には通常の検索、Menu、Picker を使用。アプリに Base UI の補完／command 検索／コンボボックスの候補・仮想化・実行連携はない。	検索・モデルメニュー・composer を開き、元の helper の呼び出し先で提供する種類の候補、選択と確定が使えるか確認する。
1264-1266 1321-1322 1329-1339 1341-1355 1370 1380-1383 1409-1411 1418 1428-1435	構成差	W:151 W:220 W:329 W:438 W:641 A:99 A:117 C:44	SwiftUI の Button、標準メニュー、TextField、Toggle、ProgressView、Divider と既存画面の help 等で関連する標準の役割を担う。Web の部品ごとの公開機能やその状態管理には対応を割り当てない。	プロジェクト・スレッド・モデルの各操作で指定の入力、ボタン、メニューや状態の機能を親の用途と一緒に確認する。
1267-1272 1277-1279 1356-1359 1361 1366-1369 1412-1417 1419-1427 1436-1437	構成差	A:99 A:117 W:438 W:597	対象の Base UI 部品は親のワークフローで照合する。カレンダー、色編集、独自ステッパー、プレビューカード、表、通知 stack、Wizard に独立したネイティブ対応を割り当てない。	指定の親画面を確認し、元の部品が担う表示・操作を持つ入口が実際にあるか確認する。
1273-1276	構成差	W:190 W:248	Settled とプロジェクトの開閉に SwiftUI の DisclosureGroup またはボタンを使う。個別の Collapsible ラッパーは親が所有する。	Settled またはプロジェクトグループを開き、指定の開閉と子の表示を確認する。
1360	構成差	A:117	Model Settings の Context window で数値用 TextField を使用。元の専用構成とイベントは共有しない。	Local provider を選び、context window を入力してエラー範囲の扱いを確認する。
1362-1365	構成差	W:438 W:476	ヘッダーのボタンから SwiftUI popover を表示する。T3 のポップオーバーのイベントと各ラッパーは親の機能で比較する。	Thread Details を開き、見出し、閉じる操作とフォーカスを確認する。
1371-1372	構成差	W:176 W:558 C:189	スレッド、履歴と diff は SwiftUI ScrollView。Web のスクロールバーとそのイベントを独立機能として割り当てない。	長い一覧または差分を用意し、指定のスクロール方向や入力で移動できることを確認する。
1373-1379	構成差	A:103 L:30 C:176	Provider、base branch、diff mode は SwiftUI の Picker。Web の Select 本体・項目・コールバックは利用先ごとに評価する。	該当 picker を開き、指定の候補を選び、利用先の状態が更新されることを確認する。
028 031	未対応	W:476 C:80 L:30	パスを選択でき、ブランチ選択の Picker がある。専用右クリックでフルパスやブランチ名をコピーする項目はない。	作業場所とブランチのメニューで対象文字列を右クリックし、独立したコピー項目があるか確認する。
034	未対応	W:615 L:18 A:99	作業場所はローカルフォルダーと worktree。別マシン、Auto balance やリンクされた環境の選択はない。	作業場所の入口から端末と Auto balance を選択できるか確認する。
024 1394-1396	未対応	W:60 W:113	左の HSplitView は範囲内の幅指定。サイドバー全体の toggle、restore ハンドルとドラッグによる畳み込みはない。	最左まで境界をドラッグし、サイドバー全体を閉じて再表示する対象操作があるか確認する。
058	部分	W:88 P:27 P:54 P:62 M:102	既存フォルダーをテキストまたは macOS のフォルダー選択から登録。T3 のパレット化、対象環境・新規フォルダー・clone・publish は同じシートでは扱わない。	既存フォルダーを指定し登録結果を確認する。相対パス、存在しないフォルダー、環境指定と clone の候補も試す。
073 313-316	構成差	W:454 W:597 W:641 W:691	SwiftUI の中央／下端配置、TextField、角丸カードと下の作業場所行。Tiptap の転送ラッパー、スロットと境界連結は親 composer の検証に含める。	下書きと本文ありの入力カードで同じ入力を行い、対象の構成要素やバナーが独立の操作を持つか確認する。
197	部分	W:284 W:429 W:514	該当行を選んでからヘッダーの Terminal を使う。未選択の行に対して直接端末を開く状態ボタンはない。	別スレッドの端末を開いた後に行を切り替え、対象行の直接操作とヘッダーで操作する場合を比較する。
203-204 206	構成差	W:524 W:546 T:18 T:29	下部に SwiftTerm の NSView を埋め込む。Ghostty・React のビューのイベント転送や汎用アクションボタンは親の Terminal drawer に帰属する。	端末で文字を入力し、表示時のフォーカス、端末と各ボタンの状態を確認する。
418	部分	W:597 W:603 M:406 M:461	失敗は入力欄の上に赤い文を表示し、closed の場合のみ Reconnect。T3 の dismiss、管理者向けコピー、専用バナーの状態はない。	ターンの失敗と helper の終了を別に起こして、対応の文面と再接続、閉じる項目、管理者向けコピーの有無を確認する。
579	構成差	C:188 C:240	パッチは等幅 Text と行先頭で選ぶ色で構成。T3 の差分描画部品の style props と設定は親の Changes の検証へ含める。	追加・削除・ハンクのある差分を選び、行の配色、テキストの選択、表示切替の有無を確認する。
1391-1392 1398-1404 1406-1407	構成差	W:60 W:113 W:176 W:248	スレッドサイドバーの組み立ては SwiftUI の split、VStack と ScrollView。React の provider／resize の解決、階層マーカーに独立したネイティブ UI は割り当てない。	左サイドバーを開き、グループ化、行の描画、幅制御のどこに対象部品の役割が現れるか確認する。
1393 1397 1405 1408	構成差	W:60 W:113 W:151 W:284	SwiftUI の検索、スレッド行 Button、選択ラベル。Web 汎用部品とは別の呼び出し元と制御を持つ。	検索、グループ化、行選択を行い、対象部品に対応する親の挙動を確認する。
"""


def require(condition, message):
    if not condition:
        raise ValueError(message)


def tsv(path):
    header, *lines = path.read_text(encoding="utf-8").splitlines()
    columns = header.split("\t")
    rows = [line.split("\t") for line in lines]
    require(all(len(row) == len(columns) for row in rows), f"Malformed TSV: {path}")
    return columns, rows


def render(columns, rows):
    return "\n".join("\t".join(row) for row in [columns, *rows]) + "\n"


def native_pointers(aliases):
    pointers = []
    for alias in aliases.split():
        key, line = alias.split(":")
        pointers.append(f"Sources/PiWorkspace/{NATIVE_FILES[key]}.swift:{line}")
    return "|".join(pointers)


def load_rules():
    rules = {}
    for group in RULES.splitlines():
        selector, status, aliases, difference, replay = group.split("\t")
        for span in selector.split():
            low, _, high = span.partition("-")
            for number in range(int(low), int(high or low) + 1):
                key = f"UI-{number:03d}"
                require(key not in rules, f"Duplicate review rule: {key}")
                rules[key] = status, native_pointers(aliases), difference, replay
    return rules


@cache
def source_lines(root, relative):
    location = root / relative
    require(location.resolve().is_relative_to(root.resolve()), f"Escaping path: {location}")
    return location.read_text(encoding="utf-8").splitlines()


def check_pointer(root, pointer, ranges=False):
    relative, _, line_range = pointer.strip().rpartition(":")
    match = re.fullmatch(r"(\d+)(?:-(\d+))?" if ranges else r"(\d+)", line_range)
    require(match, f"Malformed pointer: {pointer}")
    start = int(match[1])
    end = int(match[2] if ranges and match[2] else start)
    lines = source_lines(root, relative)
    require(1 <= start <= end <= len(lines), f"Out-of-range pointer: {pointer}")
    return lines[start - 1]


def ordered_ids(rows, expected, label):
    count = Counter(row[0] for row in rows)
    missing = sorted(set(expected) - set(count))
    extra = sorted(set(count) - set(expected))
    repeats = sorted(key for key, value in count.items() if value != 1)
    require(not (missing or extra or repeats),
            f"{label}: missing {missing}, extra {extra}, duplicate {repeats}")
    require([row[0] for row in rows] == list(expected), f"{label}: ID order differs")


def assertion_targets(feature, declarations):
    hint = feature["action"].split(" に相当するコントロール", 1)[0]
    if feature["entry"] == "対象のコンテキストメニュー":
        hint = hint.removeprefix("対象を右クリックし、").split(" に相当する項目", 1)[0]
    callback = re.search(r"([\w]+@\d+|href|to) の処理", feature["acceptance"])
    callbacks = []
    pattern = re.compile(r"(?:on[A-Z]\w*|on[a-z][a-zA-Z]+)@\d+(?==)")
    for item in declarations:
        for name in pattern.findall(item[2]):
            if name not in callbacks:
                callbacks.append(name)
    if callback and callback[1] not in callbacks[:3]:
        callbacks.insert(0, callback[1])
    callback_hint = "、".join(callbacks[:3])
    return hint + (" ／ " + callback_hint if callback_hint else "")


def ui_comparison():
    inventory = AUDIT / "inventory" / "UI"
    summary = json.loads((inventory / "summary.json").read_text())
    require(
        (summary["commit"], summary["sourceWorkflowGroups"], summary["entries"])
        == (COMMIT, 1491, 5733),
        "Frozen UI census changed",
    )
    headings, features = tsv(inventory / "features.tsv")
    _, entries = tsv(inventory / "entries.tsv")
    keys = [f"UI-{number:03d}" for number in range(1, 1492)]
    ordered_ids(features, keys, "original UI groups")
    ordered_ids(entries, [f"UI-E{number:04d}" for number in range(1, 5734)], "UI declarations")
    declarations = defaultdict(list)
    for entry in entries:
        check_pointer(T3, entry[3])
        declarations[entry[4]].append(entry)
    rules = load_rules()
    require(set(keys) == set(declarations) == set(rules), "UI groups, declarations and rules differ")

    result = []
    for row in features:
        feature = dict(zip(headings, row))
        key, title = feature["id"], feature["title"]
        anchors = feature["source"].split("|")
        for anchor in anchors:
            check_pointer(T3, anchor)
        status, swift_source, difference, replay = rules[key]
        sites = declarations[key]
        file = Path(anchors[0].rpartition(":")[0]).name
        owner = title.rsplit("・", 1)[-1]
        flags = Counter(
            flag for entry in sites
            for match in [re.search(r"\(col \d+\) \[([^\]]+)\]", entry[2])] if match
            for flag in match[1].split(",")
        )
        qualifiers = []
        for name, word in (("conditional", "条件分岐"), ("generated", "生成"), ("opaque", "静的追跡に限界")):
            if flags[name]:
                qualifiers.append(word)
        qualified = f"（{'・'.join(qualifiers)}）" if qualifiers else ""
        # File and declaration line disambiguate nested functions with the same name.
        attribution = f"T3 {file}:{anchors[0].rpartition(':')[2]} の {owner}{qualified}"
        targets = assertion_targets(feature, sites)
        coverage = f"{attribution}。宣言{len(sites)}件。{difference}"
        acceptance = f"T3 側の照合箇所は {attribution}。「{targets}」を手掛かりにする。{replay}"
        result.append([key, status, VERIFICATION, swift_source, coverage, acceptance])
    return result


def checked_comparison(columns, rows, originals, label):
    ordered_ids(rows, [row[0] for row in originals], label)
    rows_by_column = [dict(zip(columns, row)) for row in rows]
    for row in rows_by_column:
        key = row[columns[0]]
        require(all(row.values()), f"{key}: Empty comparison field")
        require(row["status"] in STATUSES, f"{key}: Invalid status")
        require(row["verification"] == VERIFICATION, f"{key}: Evidence is source only")
        for source in row["swift_source"].split("|"):
            require(source.startswith("Sources/PiWorkspace/") and ".swift:" in source,
                    f"{key}: Invalid Swift source: {source}")
            require(check_pointer(PI, source).strip(), f"{key}: Blank Swift source: {source}")
    require(len({row["acceptance"] for row in rows_by_column}) == len(rows), f"{label}: repeated replay")


def screen_check(columns, rows):
    headings, original = tsv(AUDIT / "screens" / "source" / "state-index.tsv")
    expected = [f"SRC-S{number:02d}" for number in [*range(1, 37), *range(40, 65)]]
    ordered_ids(original, expected, "original screens")
    require(headings == SCREEN_COLUMNS[:5] and columns == SCREEN_COLUMNS, "Screen schema differs")
    checked_comparison(columns, rows, original, "screen comparison")
    for baseline, comparison in zip(original, rows):
        screen_id, _, reference, commit, pointers = baseline
        require(baseline == comparison[:5], f"{screen_id}: Frozen screen fields differ")
        require(commit == COMMIT, f"{screen_id}: Wrong original commit")
        filename, anchor = reference.split("#")
        ledger = source_lines(AUDIT / "screens" / "source", filename)
        require(anchor == screen_id and f'<a id="{screen_id}"></a>' in ledger
                and any(line.startswith(f"## {screen_id} ") for line in ledger),
                f"{screen_id}: Missing ledger section")
        for pointer in pointers.split(" | "):
            check_pointer(T3, pointer, ranges=True)
        status, native = comparison[5], comparison[7]
        require(status != "未対応" or native == "なし", f"{screen_id}: Missing explicit no-screen label")


def must_reject(check, contains):
    try:
        check()
    except ValueError as error:
        require(contains in str(error), f"Expected {contains!r}, got {error!r}")
    else:
        raise ValueError(f"Corruption passed undetected: {contains}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write-ui", action="store_true", help="Regenerate UI.tsv")
    parser.add_argument("--self-test", action="store_true", help="Test corruptions in memory")
    args = parser.parse_args()
    head = subprocess.check_output(["git", "-C", str(T3), "rev-parse", "HEAD"], text=True).strip()
    require(head == COMMIT, "Expected fixed T3 commit")
    generated = ui_comparison()
    ui = COMPARISON / "UI.tsv"
    if args.write_ui:
        ui.write_text(render(UI_COLUMNS, generated), encoding="utf-8")
    ui_columns, actual = tsv(ui)
    require(ui_columns == UI_COLUMNS, "UI schema differs")
    checked_comparison(ui_columns, actual, generated, "UI comparison")
    require(render(UI_COLUMNS, generated) == ui.read_text(encoding="utf-8"), "UI.tsv differs from reviewed rules")
    screen_columns, screens = tsv(COMPARISON / "screens.tsv")
    screen_check(screen_columns, screens)
    if args.self_test:
        must_reject(lambda: checked_comparison(ui_columns, actual[1:], generated, "UI comparison"),
                    "missing ['UI-001']")
        lost_source = [row.copy() for row in actual]
        lost_source[0][3] = "Sources/PiWorkspace/WorkspaceView.swift:99999"
        must_reject(lambda: checked_comparison(ui_columns, lost_source, generated, "UI comparison"),
                    "Out-of-range pointer")
        changed = [row.copy() for row in screens]
        changed[0][2] = "01-workspace.md#SRC-S02"
        must_reject(lambda: screen_check(screen_columns, changed), "Frozen screen fields differ")
        must_reject(lambda: screen_check(screen_columns, changed[1:]), "missing ['SRC-S01']")
        print("4 negative controls passed")
    print(f"UI {len(actual)} groups / 5733 declarations. Screens {len(screens)}.")
    print("UI:", dict(Counter(row[1] for row in actual)))
    print("Screens:", dict(Counter(row[5] for row in screens)))


if __name__ == "__main__":
    main()
