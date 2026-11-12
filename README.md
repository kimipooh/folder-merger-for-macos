# Folder Merger for macOS

[日本語マニュアル](docs/user-guide-ja.md) · [English user guide](docs/user-guide-en.md)

複数フォルダの中身を、相対パスを保って新しいフォルダに統合する日英対応アプリです。入力を移動・改名・削除せず、既存出力を上書きしません。同じ相対パスのフォルダは統合し、同一内容ファイルは1件にまとめます。内容の異なる同名ファイルは、設定で中止・先に追加した入力（既定）・後に追加した入力・変更日が新しいファイルの優先を選べます。新しい方を優先する場合、同時刻・比較不可なら中止します。Unicode の正準等価な表記違いは保存先が同一視する場合に統合し、先の表記を使います。採用判断は詳細ログオフでも記録します。フォルダ属性は先の入力、ファイル属性は採用元から取得します。

A Japanese/English app that merges folder contents into a new folder, preserving relative paths. Inputs are not moved, renamed, or deleted; existing outputs are never overwritten. Same-path folders are merged and identical files are deduplicated. For different file contents at the same path, choose stop, input added first (default), input added later, or newer modification date. Newer-file priority stops on equal or incomparable dates. Canonically equivalent Unicode names merge only when the destination treats them as identical, retaining the first spelling. Selection decisions appear even without detailed logging. Folder attributes come from the earlier input; file attributes come from the selected file.

## 入手・動作環境 / Availability and requirements

macOS 13.0 以降。ソース公開先は [GitHub の main](https://github.com/kimipooh/folder-merger-for-macos/tree/main) です。Release はまだありません。公開後は [GitHub Releases](https://github.com/kimipooh/folder-merger-for-macos/releases) のアプリ入り ZIP を利用できます。`Source code (zip)` はアプリを含まないソースです。現在はソースからビルドしてください。ビルドには Xcode（Swift 5.9 以降対応）が必要です。外部パッケージ依存はありません。

Requires macOS 13.0 or later. Source is published on GitHub main. No Release is available yet; build from source using Xcode with Swift 5.9 or later. After publication, download the app ZIP from GitHub Releases; `Source code (zip)` contains source only. There are no external package dependencies.

現在のビルドは署名・公証を設定していません。App Sandbox は無効で、ユーザー権限で動作します。macOS のアクセス許可が必要になる場合があります。「アップデートを確認…」はメニュー選択時だけ通信し、更新は手動でアプリを入れ替えます。

Current builds do not configure signing or notarization. App Sandbox is disabled; the app runs with your permissions and may require macOS folder-access approval. “Check for Updates…” connects only when selected; replace the app manually to update.

初回起動がブロックされた場合は、一度起動を試してから「システム設定」→「プライバシーとセキュリティ」→「このまま開く」を選びます。新版でも再許可が必要な場合があります。

If blocked on first launch, try opening once, then go to System Settings → Privacy & Security → Open Anyway. A new version may require approval again.

## ビルドと起動 / Build and run

リポジトリのルートで実行します。生成物は一時領域に置きます。
Run from the repository root; keep build products in temporary storage.

```sh
swift test --scratch-path "$TMPDIR/fm-build"
xcodebuild -project FolderMerger.xcodeproj -scheme FolderMerger \
  -configuration Debug -derivedDataPath "$TMPDIR/fm-dd" build
open "$TMPDIR/fm-dd/Build/Products/Debug/Folder Merger.app"
```

Xcode で `FolderMerger.xcodeproj` を開き、FolderMerger スキームで Run することもできます。
Alternatively, open `FolderMerger.xcodeproj` in Xcode and run the FolderMerger scheme.

## 文書 / Documentation

- [日本語マニュアル](docs/user-guide-ja.md) / [English user guide](docs/user-guide-en.md): 操作、設定、ログ、Takeout の例 / usage, settings, logs, and Takeout examples
- [設計・検証記録](docs/design.md): 現行実装と過去の検証 / implementation and historical validation (Japanese)
- [公開・配布計画](docs/release.md): 署名・公証なしの ZIP 配布手順 / unsigned ZIP release procedure (Japanese)
- [開発ルール](AGENTS.md) / [Claude Code の役割](CLAUDE.md)

## ライセンス / License

[MIT License](LICENSE) — Copyright (c) 2026 Kimiya Kitani

## 作業ログの保存

実行後の「ログを保存…」（`Save Log…`）では「ログの種類」（「簡易ログ」/ `Summary log`、 「詳細ログ」/ `Detailed log`）と「形式」（「TXT（UTF-8）」、「CSV（UTF-8 BOM 付き）」、英語は `TXT (UTF-8)`、`CSV (UTF-8 with BOM)`）を別々に選べます。既定は簡易ログ／TXT。既定名は `FolderMerger-summary-log-20261112-120500.txt` のように種類と日時を含み、種類の変更で `summary` / `detailed` が、形式の変更で拡張子が変わります。手入力した名前の本体は維持します。場所と名前を選び、既存ファイルの置換は標準の確認に従います。保存失敗はアラートで表示します。未実行・実行中は保存できませんが、成功、警告付き完了、失敗、キャンセル、開始前の検証失敗では4通りすべてを保存できます。

「ファイルごとの詳細ログ」は画面表示だけを制御します。オフでもコピー・フォルダ作成・同一内容の省略を含む全イベントを一時ジャーナルに逐次記録し、後から詳細ログを保存できます。画面の5,000行上限とは独立しています。実行条件には「ファイルごとの詳細ログ（画面表示）」として記録します。

簡易ログは、開始・終了時刻、追加順付き入力一覧、出力予定先、適用ルール、属性保持4設定、結果、コピー・省略・警告・エラー・フォルダ作成・採用結果の件数を含みます。同名ファイルの最終採用元、採用判断で不採用となった全入力元とルール、警告・エラー・キャンセル・衝突中止を残します。通常のコピー、フォルダ作成、同一内容の省略、個々の採用判断の経過、フェーズは個別行を出しません。同一内容の入力元は不採用元に含めません。簡易 TXT は「実行条件」→「同名ファイルの採用結果」（件数・各件）→「警告・エラー」→「最終結果」の節で構成します。

簡易 CSV の列は「区分、相対パス、採用元、不採用元、適用ルール、詳細、保護した列」です。「区分」で実行条件、入力元、同名ファイルの採用結果、警告、失敗、キャンセル、衝突による中止、最終結果を絞り込めます。不採用元は `; `（セミコロンと空白）区切りで、パス自体にもこの文字列がある場合は区別できません。

詳細ログは個別操作と判断経過を時系列で保存します。詳細 CSV は「時刻、処理、相対パス、入力元、比較対象、判定、適用ルール、入力元の変更日時、比較対象の変更日時、詳細、保護した列」の11列を維持します。入力元は採用側または記録対象、比較対象は不採用側（同一内容の省略では既存の採用側）です。最終採用行の比較対象には全不採用元を `; ` 区切りで記録し、判定には走査完了状態、詳細には出力確定状態を記録します。時刻と新しい変更日時での比較は ISO 8601、ナノ秒9桁、端末のローカルUTCオフセット付きです。詳細 TXT は「実行条件」→「同名ファイルの採用結果」→「作業ログ（時系列）」→「最終結果」の順です。

両方の CSV は UTF-8 BOM 付き、RFC 4180、CRLF。両方の TXT は UTF-8 BOM なし、LFで、値内のCR・改行を `\r`・`\n` と表示します。CSV は先頭の `=`・`+`・`-`・`@`・TAB・CR・LF・全角 `＝`・`＋`・`－`・`＠` を数式として解釈させないよう `'` を1文字付けます。Unicode空白や制御・書式文字を挟んだ場合も判定し、元から `'` で始まる値は変更しません。

「保護した列」（`Protected columns`）は保護した列の固定識別子を列順に `;` 区切りで記録します。簡易 CSV は `category`, `relative_path`, `selected_input`, `rejected_inputs`, `applied_rule`, `details`。詳細 CSV は `time`, `action`, `relative_path`, `input`, `compared_with`, `decision`, `applied_rule`, `input_modified`, `compared_modified`, `details`。CSVをパーサで読んだ後、挙がった列だけ先頭の `'` を1文字除くと元の値へ復元できます。空欄は保護なしです。見出しも同じ保護を適用します。表計算画面の見え方に依存せず元の CSV とメタデータを使って復元してください。TXT・画面は元表記です。

成功・警告付き完了では「出力確定」のパスと「採用結果は確定した出力に反映されています。」を確認してください。失敗・キャンセルでは「出力は確定していません。以下は採用判断です。」と後片付け結果を確認します。簡易 TXT の採用結果節と最終結果節の両方で未確定を示します。走査途中で停止した場合は「走査未完了のため、判断済み分のみ表示しています」と注記します。判断が残っていても完成出力があるとは限りません。

保存時は一時ジャーナルをストリーム変換し、全件をメモリに保持しません。次回実行と終了時に一時ログを削除します。記録失敗は統合を止めず「ログは不完全です」と理由を示します。ログは入力パスを含みます。入力・統合出力へ自動保存・同梱しません。

## 同名ファイルの採用結果

入力一覧の番号（1、2、3…）が追加順を示し、「先に追加した入力フォルダを優先」「後に追加した入力フォルダを優先」はこの順序を指します。新しい既定値は「先に追加した入力フォルダを優先」です。「統合を中止する」を含む保存済み設定は維持し、起動時に既定値を書き込みません。見出し直下には現在の設定と「次回の実行に適用」を常時表示します。実行中の「この実行のルール」、終了後の「この結果に使用したルール」には開始時に取得した設定を表示します。

作業ログ内の独立区画「同名ファイルの採用結果」（英語: `Conflicting File Decisions`）は詳細ログオフでも表示します。内容が異なり判断した相対パスを数え、同一内容だけの省略は含めません。出力表記の相対パス、最終採用元、全不採用元、適用ルールを表示します。画面は最大1,000件で「ほか N 件（保存ログに全件）」を表示し、件数と保存ログは全件を対象にします。成功時は「採用結果は確定した出力に反映されています。」、実行中・失敗・キャンセル時は「出力は確定していません。以下は採用判断です。」を表示します。走査途中の失敗では「走査未完了のため、判断済み分のみ表示しています」と示します。

詳細 TXT は実行条件の後、時系列ログの前に同名の節を置き、件数・各件と出力の確定状態を示します。詳細 CSV は10列＋「保護した列」を維持し、「処理」を「同名ファイルの採用結果」で絞り込めます。「相対パス」「入力元」「比較対象」「適用ルール」にそれぞれ出力パス・採用元・全不採用元（`; ` 区切り）・ルールを記録します。「判定」は走査の完了状態、「詳細」は出力の確定状態です。追加値にも既存の数式保護・復元規則が適用されます。TXT と画面は元表記です（TXT の改行・CR は既存規則どおりエスケープ）。
