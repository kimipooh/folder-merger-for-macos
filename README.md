# Folder Merger for macOS

[日本語マニュアル](docs/user-guide-ja.md) · [English user guide](docs/user-guide-en.md)

複数フォルダの中身を、相対パスを保って選んだ空の統合先フォルダに直接統合する日英対応アプリです。入力を移動・改名・削除せず、既存出力を上書きしません。同じ相対パスのフォルダは統合し、同一内容ファイルは1件にまとめます。内容の異なる同名ファイルは、設定で中止・先に追加した入力（既定）・後に追加した入力・変更日が新しいファイルの優先を選べます。新しい方を優先する場合、同時刻・比較不可なら中止します。Unicode の正準等価な表記違いは保存先が同一視する場合に統合し、先の表記を使います。採用判断は詳細ログオフでも記録します。フォルダ属性は先の入力、ファイル属性は採用元から取得します。

A Japanese/English app that merges folder contents directly into a chosen empty destination folder, preserving relative paths. Inputs are not moved, renamed, or deleted; existing outputs are never overwritten. Same-path folders are merged and identical files are deduplicated. For different file contents at the same path, choose stop, input added first (default), input added later, or newer modification date. Newer-file priority stops on equal or incomparable dates. Canonically equivalent Unicode names merge only when the destination treats them as identical, retaining the first spelling. Selection decisions appear even without detailed logging. Folder attributes come from the earlier input; file attributes come from the selected file.

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

簡易ログは「最終結果」→「コピーしたファイル」→「警告・エラー」の3節です。状態、確定したコピー件数、統合先、出力の確定状態を最初に示します。コピーは確定した出力ファイル1件につき「実際のコピー元 → 確定後のコピー先」の1行だけです。同名競合では最終採用元だけを示し、フォルダ行は出しません。入力・設定・採用判断の経過・同一内容の省略・処理段階は詳細ログで確認します。

簡易 CSV の列は「区分、コピー元、コピー先、内容、保護した列」（Category, Source, Destination, Details, Protected columns）です。区分は最終結果、コピー、警告、エラー、キャンセルなどです。コピー元とコピー先は絶対パスです。

詳細 TXT は「最終結果」→「入力と設定」→「作業ログ（時系列）」の順です。詳細 CSV の列は「時刻、処理、相対パス、コピー元・採用元、コピー先・不採用元、判定、理由、補足、保護した列」（Time, Operation, Relative Path, Source / selected input, Destination / rejected input, Decision, Reason, Notes, Protected columns）です。採用判断の判定欄には採用元と不採用元を明記し、理由は1文で示します。最終採用の走査状態と出力反映状態は補足に記録します。詳細ログのコピー行には、確定予定のコピー先がその時点で一時フォルダ内にあることを補足します。

両方の CSV は UTF-8 BOM 付き、RFC 4180、CRLF。両方の TXT は UTF-8 BOM なし、LFで、値内のCR・改行を `\r`・`\n` と表示します。CSV は先頭の `=`・`+`・`-`・`@`・TAB・CR・LF・全角 `＝`・`＋`・`－`・`＠` を数式として解釈させないよう `'` を1文字付けます。Unicode空白や制御・書式文字を挟んだ場合も判定し、元から `'` で始まる値は変更しません。

「保護した列」（Protected columns）は保護した列の固定識別子を列順に `;` 区切りで示します。簡易 CSV は `category`, `source`, `destination`, `details`、詳細 CSV は `time`, `action`, `relative_path`, `source`, `destination`, `decision`, `reason`, `notes`。CSV パーサで読み、挙がった列だけ先頭の `'` を1文字除くと元の値へ復元できます。空欄は保護なしです。見出しにも同じ保護を適用します。元から `'` で始まる値は変更しません。

成功・警告付き完了では出力確定を確認してください。失敗・キャンセルでは冒頭に「出力は確定していません（統合先には何も追加されていません）。」と表示し、簡易ログにコピーを列挙しません。後片付け・ロールバック失敗時はこの無追加の断定をせず、失敗と残った項目のパスを示します。警告・エラーは、できなかった処理、対象、続行または中止を記録し、システムの理由や属性名は「補足」に示します。

保存時は一時ジャーナルをストリーム変換し、全件をメモリに保持しません。次回実行と終了時に一時ログを削除します。記録失敗は統合を止めず「ログは不完全です」と理由を示します。ログは入力パスを含みます。入力・統合出力へ自動保存・同梱しません。

## 同名ファイルの採用結果

入力一覧の番号（1、2、3…）が追加順を示し、「先に追加した入力フォルダを優先」「後に追加した入力フォルダを優先」はこの順序を指します。新しい既定値は「先に追加した入力フォルダを優先」です。「統合を中止する」を含む保存済み設定は維持し、起動時に既定値を書き込みません。見出し直下には待機中・終了後は現在の設定、統合中は開始時に取得した「この実行のルール」を表示します。統合中に現在の設定が開始時のルールと異なる場合だけ「変更したルールは次回の統合から適用します」を表示し、終了時に消します。「同名ファイルの採用結果」と保存ログには実際に使用したルールを残します。

作業ログ内の独立区画「同名ファイルの採用結果」（英語: `Conflicting File Decisions`）は詳細ログオフでも表示します。内容が異なり判断した相対パスを数え、同一内容だけの省略は含めません。最終採用元と不採用元を示し、採用元だけを確定後のコピー元として簡易ログに記録します。画面は最大1,000件で「ほか N 件（保存ログに全件）」を表示します。走査状態と出力の確定状態は区別して記録します。

詳細の「フォルダ作成（一時フォルダ）」「コピー（一時フォルダ）」は構築中の処理で、確定済みの出力ではありません。「内容が同じため省略」は重複の省略、「同名ファイルの採用判断（途中）」は比較ごとの採用元・不採用元・ルール・理由です。変更日時の比較では双方の日時を理由に記録します。「同名ファイルの最終採用」は最後の採用判断で、「確定した出力に反映。」または「出力は確定していません。」を補足します。走査未完了なら判定に注記します。「出力を確定」が成功を、「ロールバック」が確定途中の項目を一時フォルダへ戻したことを示します。日時は ISO 8601、ナノ秒9桁、ローカル UTC オフセット付きです。最終採用の不採用元は `; ` 区切りのため、パスに同じ文字列があると区別できません。

## 統合先の選択 / Choosing the destination

「統合先フォルダを選択…」/ `Choose Destination Folder…` で空のフォルダを直接選択します。標準の「新規フォルダ」/ `New Folder` で作成でき、追加階層は作りません。隠し項目を含め空である必要がありますが、`.DS_Store` は空判定で無視し、読みも削除もしません。統合先と入力の重複・入れ子は使えません。

Choose the empty destination itself; create it with New Folder in the standard dialog if needed. No extra level is added. Hidden items count as contents except `.DS_Store`, which is ignored and kept untouched. Inputs and destination must not overlap or nest.

統合先内の権限 0700 の一時フォルダで構築し、各項目を `RENAME_EXCL` で排他的に確定します。失敗時は移動済み項目を戻し、確定開始前のキャンセルも一時出力を片付けます。統合先自体と `.DS_Store`、他の処理が追加した項目を保持し、確定前の状態へ戻します。確定開始後のキャンセルは確定またはロールバックまで保留します。統合先の属性・権限は置き換えません。

A private mode-0700 temporary folder inside the destination holds construction. Each item is published exclusively with RENAME_EXCL; failures roll published items back. Cancellation before publication cleans temporary output. The chosen folder, `.DS_Store`, and externally added items are preserved. Cancellation during publication is deferred until publication or rollback finishes.

見出し下は待機中・終了後に現在のルール、統合中に開始時のルールを表示します。実行中の設定が異なる場合だけ「変更したルールは次回の統合から適用します」と案内します。実際の採用ルールは結果とログに残ります。

The heading shows the current rule while idle and after completion, and the captured rule during a merge. “The changed rule will apply to the next merge.” appears only when the setting differs during a run. Results and logs retain the rule actually used.
