# ソース公開とバイナリ配布

[README](../README-ja.md) · [設計](design.md) · [日本語マニュアル](user-guide-ja.md) · [English guide](user-guide-en.md) · [MIT License](../LICENSE)

## 現行方針

ソースは GitHub `kimipooh/folder-merger-for-macos` の `main` で公開し、動作確認済みアプリ入り ZIP は GitHub Releases で配布する。1.0.0 の入手先は [v1.0.0](https://github.com/kimipooh/folder-merger-for-macos/releases/tag/v1.0.0)、最新版は [latest](https://github.com/kimipooh/folder-merger-for-macos/releases/latest) を案内する。アプリ入り ZIP は `Folder-Merger-v1.0.0-macOS-Apple-Silicon.zip`。GitHub 自動生成の `Source code (zip)` / `Source code (tar.gz)` はソースのみでアプリを含まない。対応環境は macOS 13.0 以降、Apple Silicon（arm64）専用で、Intel Mac 用バイナリは配布しない。

Developer ID 署名・Apple 公証なしで配布する。CODE_SIGNING_ALLOWED=NO、App Sandbox 無効を維持する。公開用バンドル ID は `io.github.kimipooh.foldermerger`。仮値 `org.foldermerger.local` から公開用 ID に変更するため、旧 ID の設定は引き継がれない。表示版は MARKETING_VERSION（CFBundleShortVersionString、1.0.0）、ビルド番号は CURRENT_PROJECT_VERSION（CFBundleVersion、1）。標準 About パネルの著作権表示は NSHumanReadableCopyright（`© 2026 Kimiya Kitani`、日英共通）。1.0.0 以降の同じバンドル ID のアプリ入れ替えでは UserDefaults の属性保持4設定と同名ファイルの優先設定を維持し、詳細ログは毎起動オフとする。

「アップデートを確認…」/ `Check for Updates…` はメニュー選択時だけ最新正式 Release を照会する。自動ダウンロード・インストール・再起動は行わない。新しい版は「リリースページを開く」/ `Open Release Page` から取得し、旧版を終了して `.app` を手動で入れ替える。結果別の説明は日英マニュアルを参照。

初回起動がブロックされたら、一度起動を試す →「システム設定」→「プライバシーとセキュリティ」→「このまま開く」。新版でも再許可が必要な場合がある。

本書は実行済みの公開や承認を意味しない。remote 操作、タグ・Release 作成、アップロードは明示指示を得た別工程とする。

## リリース対象とビルド

1. 公開対象の差分・未追跡ファイル・履歴を確認し、内部資料、実データ、個人情報、絶対パス、認証情報を含めない。MIT License と `Copyright (c) 2026 Kimiya Kitani` を維持する。
2. `main` のリリース対象コミットを特定し、クリーンな作業ツリーでテスト・ビルドする。タグと ZIP は必ず同じコミットに対応させる。既存タグを使う場合は `git rev-parse HEAD` と `git rev-parse '<release-tag>^{commit}'` を照合する。タグ作成は別途明示指示による。
3. MARKETING_VERSION とタグを照合する。タグは任意の先頭 v/V を除く非負整数のドット区切り。欠けた末尾成分は0とし、例えば表示1.0.0とタグ v1.0.0 は同版。接尾辞・空成分を使わない。配布ビルドで版を独自に上書きせず、そのコミットの設定を使用する。
4. 以下をリポジトリルートで実行する。生成物は同期ストレージ外の一時領域へ置く。

```sh
swift test --package-path macos --scratch-path "$TMPDIR/fm-build"
release_work=$(mktemp -d "${TMPDIR%/}/fm-release.XXXXXX")
xcodebuild -project macos/FolderMerger.xcodeproj -scheme FolderMerger \
  -configuration Release -arch arm64 -derivedDataPath "$release_work/dd" build
release_app="$release_work/dd/Build/Products/Release/Folder Merger.app"
plutil -p "$release_app/Contents/Info.plist"
lipo -archs "$release_app/Contents/MacOS/Folder Merger"
open "$release_app"
```

版 1.0.0・ビルド 1・公開用バンドル ID・著作権表示、`lipo -archs` が `arm64` のみであること、資源バンドル、日英画面・標準メニュー、人工データでの統合と入力不変・既存出力保護を確認する。同じ ID の旧版で属性保持設定を変更し、終了後に新版へ入れ替え、保存値が残ることを確認する。検証で変更した設定は元に戻す。更新確認の自動テストは固定レスポンスのみを使う。

## ZIP 作成と展開確認

ローカル起動の確認後、未使用のファイル名で ZIP を作成する。ZIP 名は `Folder-Merger-v<版>-macOS-Apple-Silicon.zip` とし、例の版番号は対象タグの版へ合わせる。既存 ZIP・正式配布物を上書きしない。

```sh
ditto -c -k --sequesterRsrc --keepParent "$release_app" \
  "$release_work/Folder-Merger-v1.0.0-macOS-Apple-Silicon.zip"
release_verify=$(mktemp -d "${TMPDIR%/}/fm-release-check.XXXXXX")
ditto -x -k "$release_work/Folder-Merger-v1.0.0-macOS-Apple-Silicon.zip" "$release_verify"
plutil -p "$release_verify/Folder Merger.app/Contents/Info.plist"
open "$release_verify/Folder Merger.app"
```

別の一時領域に展開したアプリで、bundle 内容・版・日英資源・起動・人工データ統合を再確認する。署名・公証済みとは案内しない。ZIP の検証完了後に検証済み ZIP を永続成果物として保存し、この作業で生成した展開済み `.app` を片付ける。検証前に既存配布物を削除しない。生成物は一時領域で扱い、リポジトリ内へ作らない。

公開指示を得た後、対象コミットのタグへ Release を対応させ、検証済みのアプリ入り ZIP を asset として掲載する。Release 説明に対応 macOS、Apple Silicon 専用、版、署名・公証なし、初回起動の許可手順、手動入れ替え、MIT License を記載する。ZIP と対象コミットを照合できる記録を残す。

## 公開前チェックリスト

- [ ] 差分・履歴・未追跡ファイルに内部資料・実データ・秘匿情報がない。
- [ ] 英日 README、日英マニュアル、設計、LICENSE、内部リンクとカタログの UI 文言が一致する。
- [ ] テスト、ビルド、空白、BOM、日英画面と標準メニューの結果を記録した。
- [ ] タグと ZIP が同じコミットで、MARKETING_VERSION とタグが同版である。
- [ ] ZIP 展開後の内容・起動・設定保持・人工データ統合を確認した。
- [ ] `local-build/` と `*.app` を Git に含めず、検証後の中間物を片付けた。
- [ ] 署名・公証なしと手動更新の説明があり、アプリ入り ZIP と Source code を区別した。
- [ ] 公開・タグ・Release 作成・外部送信の明示指示を得た。

## 将来の選択肢

Developer ID 署名・Apple 公証、Sparkle と appcast.xml による更新配信は将来の別タスクとして検討できる。現行の初回 Release の前提ではなく、いずれも未導入である。
