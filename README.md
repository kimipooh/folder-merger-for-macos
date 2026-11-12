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

実行後は作業ログ欄の「ログを保存…」（英語表示では `Save Log…`）で、直前の実行を CSV または TXT に保存できます。未実行・実行中は無効です。完了・警告ありで完了・失敗・キャンセルのいずれでも保存でき、開始時の検証失敗も記録されます。保存ダイアログで形式、ファイル名、場所を選びます。既定名には日時が入り、形式を変えると拡張子も変わります。既存ファイルの置換は標準の確認に従い、保存失敗はアラートで表示します。

CSV は数式として解釈され得る値の先頭に `'` を付け、加工した列を「保護した列」に記録します。復元方法は[日本語マニュアル](docs/user-guide-ja.md)を参照してください。CSV は UTF-8 BOM 付き、RFC 4180 の CRLF 区切りです。列は「時刻、処理、相対パス、入力元、比較対象、判定、適用ルール、入力元の変更日時、比較対象の変更日時、詳細、保護した列」の順です。入力元は採用した側または記録対象、比較対象は不採用側（同一ファイル省略では既存の採用側）です。相対パスは出力の表記です。「同名ファイルの採用結果」行で、3入力以上でも最終的な採用元を確認できます。「変更日が新しいファイルを優先」では双方の変更日時をナノ秒9桁・実行端末のローカルオフセット付きで記録します。時刻は ISO 8601 形式でナノ秒9桁・実行端末のローカルオフセット付きです。採用結果行は走査完了後に記録し、走査中の失敗・キャンセル時は判断済み分を走査未完了として記録します。TXT は UTF-8 BOM なし、LF 区切りで「実行条件」→「同名ファイルの採用結果」→「作業ログ（時系列）」→「最終結果」の順です。パス内の改行は TXT では `\r`・`\n` で表します。

入力の順序・出力予定先・属性保持4設定・優先ルール・詳細ログ設定、開始／終了時刻、結果と件数を含みます。失敗・キャンセル時は出力が未確定であることと一時出力の後片付け結果、成功時は確定した出力先を記録します。詳細ログがオフでも採用判断・最終採用・同一ファイル省略・衝突中止・警告・エラー・キャンセルを保存します。コピーとフォルダ作成の個別記録は詳細ログ設定に従います。画面の5000行上限で省略された分も保存対象です。

保存用の記録は入力・出力外の一時領域へ逐次書き出し、保存時にストリーム変換します。次の実行開始時とアプリ終了時に一時ログを削除します。一時記録に失敗しても統合は続け、保存内容に「ログは不完全です」と理由を示します。ログは入力元のパスを含むため共有先に注意してください。入力や統合先への自動保存・同梱はしません。

## 同名ファイルの採用結果

入力一覧の番号（1、2、3…）が追加順を示し、「先に追加した入力フォルダを優先」「後に追加した入力フォルダを優先」はこの順序を指します。新しい既定値は「先に追加した入力フォルダを優先」です。「統合を中止する」を含む保存済み設定は維持し、起動時に既定値を書き込みません。見出し直下には現在の設定と「次回の実行に適用」を常時表示します。実行中の「この実行のルール」、終了後の「この結果に使用したルール」には開始時に取得した設定を表示します。

作業ログ内の独立区画「同名ファイルの採用結果」（英語: `Conflicting File Decisions`）は詳細ログオフでも表示します。内容が異なり判断した相対パスを数え、同一内容だけの省略は含めません。出力表記の相対パス、最終採用元、全不採用元、適用ルールを表示します。画面は最大1,000件で「ほか N 件（保存ログに全件）」を表示し、件数と保存ログは全件を対象にします。成功時は「採用結果は確定した出力に反映されています。」、実行中・失敗・キャンセル時は「出力は確定していません。以下は採用判断です。」を表示します。走査途中の失敗では「走査未完了のため、判断済み分のみ表示しています」と示します。

TXT は実行条件の後、時系列ログの前に同名の節を置き、件数・各件と出力の確定状態を示します。CSV は10列＋「保護した列」を維持し、「処理」を「同名ファイルの採用結果」で絞り込めます。「相対パス」「入力元」「比較対象」「適用ルール」にそれぞれ出力パス・採用元・全不採用元（`; ` 区切り）・ルールを記録します。「判定」は走査の完了状態、「詳細」は出力の確定状態です。追加値にも既存の数式保護・復元規則が適用されます。TXT と画面は元表記です（TXT の改行・CR は既存規則どおりエスケープ）。
