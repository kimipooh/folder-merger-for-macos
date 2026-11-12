# Folder Merger for macOS

[日本語マニュアル](docs/user-guide-ja.md) · [English user guide](docs/user-guide-en.md)

複数フォルダの中身を、相対パスを保って新しいフォルダに統合する日英対応アプリです。入力を移動・改名・削除せず、既存出力を上書きしません。同じ位置の同一内容ファイルは1件にまとめ、内容や名前が衝突した場合は中止します。

A Japanese/English app that merges folder contents into a new folder, preserving relative paths. Inputs are not moved, renamed, or deleted; existing outputs are never overwritten. Identical files at the same path are deduplicated; conflicting contents or names stop the merge.

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
