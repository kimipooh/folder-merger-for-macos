# Folder Merger for macOS

複数フォルダの中身を、指定した名前の新しいフォルダにまとめる日本語・英語対応の macOS アプリです。入力フォルダ自体の名前は含めず、その直下からの相対パスを保ちます。入力を移動・改名・削除せず、内容と更新日時も変更しません。既存フォルダへの追記機能はありません。

## 動作環境

- Deployment target: macOS 13.0 以降。外部依存なし。
- 検証環境: macOS 27.2 (26B123)、Xcode 27.2 (27B52)、Apple Swift 6.4.2、Apple Silicon。
- App Sandbox は無効です。ユーザーの権限でアクセスする、ローカルビルド用途のアプリです。署名・公証・App Store 配布は対象外です。macOS のプライバシー保護によるアクセス許可が別途必要になる場合があります。
- バンドル ID `org.foldermerger.local` は仮の値です。公開前に変更してください。

## ビルドと起動

コアはルートの Swift Package、アプリは `FolderMerger.xcodeproj` です。出力先には一時領域を指定します。

```sh
swift test --scratch-path "$TMPDIR/fm-build"
xcodebuild -project FolderMerger.xcodeproj -scheme FolderMerger \
  -configuration Debug -derivedDataPath "$TMPDIR/fm-dd" build
open "$TMPDIR/fm-dd/Build/Products/Debug/Folder Merger.app"
```

Xcode で `FolderMerger.xcodeproj` を開き、FolderMerger スキームで Run することもできます。

## 操作

1. Finder から入力一覧へ複数フォルダをドロップするか、「入力フォルダを追加…」で選択します。不要な項目は個別に削除できます。一覧にはフルパスが表示されます。
2. 保存先となる親フォルダを選択し、出力フォルダ名を入力します。画面上の「作成先」を確認します。
3. 構成エラーがない状態で「統合」を押します。走査中は検出件数、構築中は処理件数 / 総件数とコピー済みバイト数が表示されます。走査・比較・コピーはバックグラウンドで実行します。
4. 完了後は「Finder で表示」で出力を確認できます。エラーメッセージとパスは選択・コピーできます。

処理中は入力を編集できません。「キャンセル」は走査・比較・コピーのチャンク境界で反映され、停止と一時データの削除が終わってから操作可能になります。確定が既に完了した後のキャンセルは成功した出力を削除しません。

入力不足、不正な名前、既存出力、入力同士の重複・入れ子、保存先が入力内にある場合は統合ボタンを無効化します。実行時にも再検証します。内容の衝突や特殊ファイルはバックグラウンドの走査・構築時に検出します。

## 統合の規則

- 同じ相対パスのフォルダは統合し、空フォルダも作成します。
- 同じ相対パスのファイルは、サイズと実際のバイト列を比較し、内容が一致する場合だけ 1 件にします。サイズや更新日時が一致するだけでは同一とみなしません。
- 内容の異なるファイル、ファイルとフォルダ、保存先で同一視される名前の衝突は中止します。元の両方の相対パスと入力フルパスを表示します。上書きや自動改名はしません。
- 大文字小文字、Unicode の NFC/NFD の区別は保存先ファイルシステムの実際の排他的作成結果に従います。case-sensitive ボリュームでは `Photo.jpg` と `photo.jpg` を別ファイルとして保存できます。内部パスのキーも Unicode 正規化をしない UTF-8 バイト列です。
- 入力内部のシンボリックリンク（壊れたリンクを含む）はたどらず、FIFO、ソケット、デバイスなどの特殊ファイルとともにエラーにします。入力ルート自体のシンボリックリンクも使用できません。親フォルダや途中のパスに別名があっても device/inode と祖先を確認して重複・入れ子を検出します。
- `.DS_Store` はどの階層でも走査・比較・コピー対象から除外します。他の隠しファイルは通常どおり処理します。
- 通常ファイルの内容を POSIX コピーで保持し、属性は次の設定に従います。出力ルートと内部フォルダの権限は通常の `mkdir(..., 0777)` と同様に umask が適用されます。
- 実行中は入力や保存先を他のアプリで編集しないでください。入力全体の時点スナップショットを作る機能はありません。

## 属性の保持

| 設定 | 初回既定値 | 説明 |
| --- | --- | --- |
| ファイルの作成日・変更日を保持 | オン | Finderに表示されるファイルの「作成日」と「変更日」を引き継ぎます。 |
| ファイルのアクセス権を保持 | オン | ファイルの読み取り・書き込み・実行の権限を引き継ぎます。通常はオンのままで使えます。 |
| フォルダの作成日・変更日を保持 | オフ | フォルダ自体の日付も記録として残したい場合にオンにします。同じ位置のフォルダを統合するときは、入力一覧で先にあるフォルダの日付を使います。 |
| Finderタグなど、Mac固有の情報も保持（技術名: 拡張属性・リソースフォーク） | オン | Finderで付けたタグや、一部のMac用ファイルに付属するデータを引き継ぎます。通常はオンのままで使えます。 |

説明文は各チェック項目の直下に常時表示し、「詳細」で技術名、Takeout の内容、非対応時の警告を確認できます。Takeout の写真・動画に埋め込まれた撮影情報（EXIF 等）と付属 JSON は、チェック状態にかかわらずファイル内容としてコピーします。

Mac 固有情報の初回既定値をオンに変更しました。既存コードでは設定の保存は `didSet` のみで、起動時に初期値を書き込む経路がないことを確認しました。キー `merge.preserveExtendedAttributes` が未保存ならオン、保存済みならオン・オフどちらの値も維持します。読込みは値を保存しません。

### Attribute settings (English)

| Setting | Initial default | Description |
| --- | --- | --- |
| Preserve file creation and modification dates | On | Keeps the original file dates shown in Finder. |
| Preserve file permissions | On | Keeps the original read, write, and execute permissions. Leave this on for normal use. |
| Preserve folder creation and modification dates | Off | Turn this on to keep the dates of the folders themselves. When folders at the same relative path are merged, the first one in the input list supplies the dates. |
| Preserve Finder tags and other Mac metadata (extended attributes and resource forks) | On | Keeps Finder tags and additional data used by some Mac files. Leave this on for normal use. |

Descriptions always appear below each checkbox. Details explains extended attributes and resource forks, Takeout contents, and unsupported attributes. Shooting information (such as EXIF) embedded in Takeout photos and videos, and accompanying JSON files, are copied as file contents regardless of these settings.

The initial default for Mac metadata is now on. The previous code only saved settings in `didSet`; it did not write initial values at launch. If `merge.preserveExtendedAttributes` has no saved value, it defaults to on. Previously saved values, both on and off, remain unchanged. Reading the setting does not save it.

If the destination does not support an attribute (`ENOTSUP` / `EOPNOTSUPP`), warnings show the affected relative path, attribute, and reason. Copying continues and the result is “Completed with warnings”. Other attribute errors stop the merge and trigger cleanup.

### 表示言語 / Display language

macOS のシステムまたはアプリごとの言語設定に従い、日本語・英語を表示します。対応外の言語は英語にフォールバックします。アプリ内の言語切替はありません。ファイル名・パスは翻訳しません。

The app follows the macOS system or per-app language setting. Japanese and English are supported; other languages fall back to English. There is no in-app language switch. File names and paths are displayed unchanged.

App とコアの文言はそれぞれ `Localizable.xcstrings` で管理し、開発言語は英語です。コアは Swift Package の資源バンドルから読み込み、SwiftPM と Xcode の両方でカタログをコンパイルします。

4 項目は UserDefaults に保存し、次回起動時に復元します。安定キーは `merge.preserveFileDates`、`merge.preserveFilePermissions`、`merge.preserveDirectoryDates`、`merge.preserveExtendedAttributes` です。オフの属性は元から明示的に複製せず、OS の新規作成値を使います。権限オフ時のファイルは `open(..., 0666)` に umask を適用した権限になります。

内容の書込み → 拡張属性 → ファイル権限 → mtime → 作成日（`setattrlist/ATTR_CMN_CRTIME`）の順です。読み取り専用ファイルも書込み完了後に権限を適用します。フォルダは子の作成・コピー完了後、深い階層から属性を適用します。同一相対パスが複数入力にある場合、ファイルもフォルダも入力一覧の最初の項目から属性を採用します。内容が同じファイルの後続入力はコピーを省略します。出力最上位フォルダには入力ルートの日時・属性・権限を継承しません。

アクセス日時は保持しません。読み取りによる入力のアクセス日時更新も抑制しません。所有者・グループ・ACL は複製しません。EXIF 等のファイル内部メタデータは編集せず、ファイル内容としてそのままコピーします。

拡張属性オンでは、元に列挙された属性を名前・値ごとにコピーします。`com.apple.quarantine` も除外せず保持するため、出力にも OS の隔離扱いが引き継がれます。`com.apple.rootless` などシステムが保護する属性は、設定時に `EPERM` となる場合があり、その場合は仕様上「その他の属性エラー」として処理を中止し、一時フォルダを片付けます（警告にはしません）。通常ファイルで `com.apple.rootless` の書込み `EPERM`、`com.apple.provenance` と `com.apple.macl` の書込み成功を確認しています。属性非対応を示す `ENOTSUP` / `EOPNOTSUPP` が保存先への適用で返った場合は、相対パス・属性名・理由を警告として記録し、他の属性とコピーを継続して「警告ありで完了」とします。その他の属性エラー、属性の読取りエラー、内容の読み書きエラーは中止して一時フォルダを片付けます。

## 処理内容と作業ログ

「処理内容を表示」は既定で折りたたみです。コアの `MergePlanDescription` が、入力の処理順（属性採用の優先順）、確定先、属性設定、同一ファイル・衝突・除外の規則、一時フォルダと `RENAME_EXCL`、POSIX コピー方式を説明します。外部コマンド引数は `nil` です。実行開始時の説明を値型のスナップショットで保存し、実行後に設定を変えても実行済みの説明は変わりません。次の実行を開始すると更新します。

「作業ログ」は既定で表示し、段階・現在の項目・コピー件数・同一ファイル省略件数・警告とエラーの件数・最終結果を表示します。「ファイルごとの詳細ログ」は起動時オフ、保存せず、実行中は変更不可です。オンでは実際に終えたフォルダ作成・ファイルコピー・比較後の同一ファイル省略を、相対パス、採用元または省略元の入力、コピーのバイト数とともに時系列で表示します。コピー件数は内容のコピー完了時に加算し、以後に属性エラー等で全体が失敗した場合にも実行済み件数として残します。

警告・エラー・キャンセル・完了は詳細設定にかかわらず通知します。コアの `MergeEvent` と `MergeResult` が件数と「完了／警告ありで完了／失敗／キャンセル」を管理し、既存の `merge` API は URL を返す従来の呼出し用として維持しています。警告を取得する呼出しでは `run` の結果を使います。

ログと進捗はバックグラウンドでバッファし、最大約 150 ms 間隔でメインスレッドへ反映します（終了時は即時反映）。表示は最大 5,000 行で、バッファまたは画面で除いた行数を「n 行を省略」と表示します。件数・最終結果・全警告一覧・失敗内容は行数上限とは別に保持します。ログとパスはテキスト選択できます。

## コピー方式と失敗時の扱い

この Mac の `/usr/bin/rsync --version` は `openrsync: protocol version 29` / `rsync version 2.6.9 compatible` でした。`--times` の人工データでの動作も確認しています。rsync は第一候補として検討しましたが、内容の厳密な比較、チャンクごとのキャンセル、保存先での名前衝突の検出を一つの処理で管理するため、Foundation と POSIX の `open/read/write` を採用しました。統合処理から外部プロセスは起動しません。

比較・コピーは最大 1 MiB のバッファで実行します。ファイル全体をメモリに載せません。保存先親フォルダ内に `.<出力名>.foldermerger-<UUID>.tmp` を作り、`mkdir` と `O_CREAT | O_EXCL` で構築します。全成功時だけ `renamex_np(RENAME_EXCL)` で新規出力へ原子的に確定します。確定直前に別プロセスが同名項目を作っても、その項目を保持して失敗します。

失敗・キャンセル時は、処理とファイルのクローズを完了してから、この実行の一時フォルダだけを削除します。完成した出力名は残しません。後片付けに失敗した場合は、一時フォルダのパスをエラーに表示します。強制終了や電源断の際は一時フォルダが残ることがあります。アプリを終了して処理が停止していることを確認してから、該当する一時フォルダを手動で片付けてください。

## Google Takeout の例

分割して取得・解凍した `Takeout`、`Takeout 2`、`Takeout 3` を入力として選びます。入力の外にある別の親フォルダを保存先に選び、出力名を `Takeout` にします。元フォルダを改名する必要はありません。

```text
入力: Takeout/Google フォト/アルバム/IMG.jpg
入力: Takeout 2/Google フォト/アルバム/動画.mp4
入力: Takeout 3/Google フォト/アルバム/IMG.jpg.json
出力: <保存先>/Takeout/Google フォト/アルバム/IMG.jpg
出力: <保存先>/Takeout/Google フォト/アルバム/動画.mp4
出力: <保存先>/Takeout/Google フォト/アルバム/IMG.jpg.json
```

ZIP 解凍、メタデータに基づく撮影日時の補正は行いません。

## 検証

自動テストは実行時に一時領域へ作る人工データのみを使用します。既存 25 件（日時、権限、xattr、フォルダ後処理、入力順、非対応警告とその他のエラー、イベントと件数、キャンセル、説明スナップショット等）に、設定既定値 3 件と日英リソース・全キー翻訳・複数形の 3 件を追加し、計 31 件が成功しました（2026-11-11）。同日の Xcode Debug ビルドも成功しました。生成アプリとコアの資源バンドルには en/ja の文字列・複数形辞書が含まれます。生成資源を使った一時検証プログラムで、英語・日本語と、フランス語指定時の英語フォールバックを確認しました。

通常の一時領域での実測（`stat` / `listxattr` / `getxattr` による `stat -f '%SB %Sm %Sp'`・`xattr -l` 相当の確認）:

- 作成日 `981158400.987654321`（2001-02-03 UTC）と mtime `1118102400.123456789`（2005-06-07 UTC）を別々に設定し、mtime → 作成日の順で秒・ナノ秒が両方一致しました。日時オフ時は両方がテスト開始時刻以降でした。
- ファイル権限 `0640` / `0400` を保持し、オフでは新規作成ファイルの既定権限と一致しました。日時実測ファイルの権限は `0600` でした。
- ファイルとフォルダの `user.foldermerger-test`、Finder タグ `com.apple.metadata:_kMDItemUserTags`、`com.apple.FinderInfo`、`com.apple.quarantine` はオンで同じ値、オフで複製されないことを確認しました。
- ファイルの `com.apple.ResourceFork` も同様に確認しました。フォルダへのリソースフォーク設定はこの環境で `EPERM` となり、実物でのフォルダリソースフォーク複製は未検証です。実装はフォルダでも列挙された属性を同じ経路で扱います。
- 子を持つフォルダの日時が後処理後も一致し、出力ルートには入力ルートの日時・属性が継承されませんでした。入力順の反転で採用される日時・ファイル権限・xattr も入れ替わりました。
- 通常の一時領域は大文字小文字を区別せず、NFC/NFD も同一視し、名前衝突として停止しました。
- `ENOTSUP` スタブで警告あり完了、`EACCES` スタブで失敗・後片付けを確認しました。FAT イメージの実測は行っていません。非対応経路は必須のスタブ検証で確認し、実ボリューム別の対応状況は未検証です。

Case-sensitive APFS イメージでは以前の 15 件の確認実績がありますが、今回追加した属性テストは通常の一時領域での結果です。

Case-sensitive APFS で追加確認する場合は、`hdiutil create -size 256m -fs "Case-sensitive APFS" -volname FMCaseTest -type SPARSE -o "$TMPDIR/fm-case-test.sparseimage"` でイメージを作り、`hdiutil attach` でマウントして `FM_CASE_TEST_ROOT` に指定します。確認後は `hdiutil detach` で取り外します。
