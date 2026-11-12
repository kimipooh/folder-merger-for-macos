# 開発ルール（Codex / Claude Code 共通）

## 不変条件と変更範囲

- 入力の内容・更新日時を変更せず、移動・改名・削除しない。読取りによるアクセス日時更新は抑制していない。
- 既存出力を上書きしない。一時出力・排他的作成・RENAME_EXCL による確定と、失敗・キャンセル時の後片付けを維持する。
- 現行コードを正とし、依頼範囲だけを変更する。既存機能・テスト・未コミット変更を保護する。
- 作業前にリポジトリルート、ブランチ、作業ツリーを確認する。コミット・ブランチ・remote 操作は当該タスクの明示指示に従う。

## 文字列と文書

UI の独自文字列は `App/Localizable.xcstrings`、エンジンの文字列は `Sources/FolderMergerCore/Resources/Localizable.xcstrings` で管理する。英語と日本語の全キー、書式引数、複数形を揃える。コアは Bundle.module から読み込む。SwiftUI の標準 Settings メニューはこのカタログに含まれない。

仕様や操作を変える場合、[README](README.md)、[日本語マニュアル](docs/user-guide-ja.md)、[英語マニュアル](docs/user-guide-en.md)、[設計](docs/design.md)を同時に点検・更新する。UI 名称・既定値・保存挙動をコードとカタログへ照合する。未実装機能を実装済みと書かない。

機械向け Markdown（本書・CLAUDE.md 等）と新規 Markdown は UTF-8 BOM なし。既存の人間向け Markdown は BOM 有無を維持し、変更後に実バイトで確認する。

## 検証

macOS と Xcode のある環境で、リポジトリルートから実行する。

```sh
swift test --scratch-path "$TMPDIR/fm-build"
xcodebuild -project FolderMerger.xcodeproj -scheme FolderMerger \
  -configuration Debug -derivedDataPath "$TMPDIR/fm-dd" build
git diff --check
```

テストは一時領域の人工データを使う。swift test は統合エンジン、設定既定値、日英カタログの全キー・引数・複数形を検証する。UI 変更時は Xcode ビルドに加え、日英の画面・標準メニューも確認する。文書のみの変更はリンク・UI 名称・秘匿情報・BOM と関連テストを確認する。未追跡ファイルは git diff --check の対象外なので、別途末尾空白等を確認する。失敗・実行不可は理由とともに報告し、未実施を成功扱いしない。

## 公開・生成物

- 個人の絶対パス、実データ名、研究データ、メールアドレス、認証情報、秘密鍵を公開物に含めない。例は人工名・相対パス・プレースホルダーを使う。
- `local-build/` と `*.app` はコミットしない。依存定義・テスト・正式な既存配布物を生成物として削除しない。
- 同期ストレージ上に展開状態の .app を恒久保存しない。ビルド・検証は一時領域で行い、配布は `ditto -c -k --sequesterRsrc --keepParent "Folder Merger.app" "Folder-Merger-macos.zip"` で ZIP 化する。
- ZIP を別の一時領域へ展開し、bundle 内容・署名（配布時）・起動を確認してから、この作業で作った展開済み .app を片付ける。検証前に既存 ZIP・正式配布物を削除・上書きしない。
- 署名・公証・公開・更新配信は[配布計画](docs/release.md)とタスクの権限境界に従う。
