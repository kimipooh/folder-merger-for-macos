# Folder Merger for macOS

[English](README.md) | 日本語

## 概要

Folder Merger は、複数フォルダの中身を相対パスを保って選んだ空の統合先に直接まとめる、日英対応の macOS アプリです。

## 主な機能

- 「統合先フォルダを選択…」で空の統合先を直接選び、必要なら「新規フォルダ」で作成できます。追加の階層は作りません。
- 同じ相対パスのフォルダを統合し、内容が同じファイルは1件にまとめます。
- 内容の異なる同名ファイルは、既定で「先に追加した入力フォルダを優先」します。設定で「統合を中止する」「後に追加した入力フォルダを優先」「変更日が新しいファイルを優先」も選べます。
- 入力を変更せず、既存の項目を上書きしません。
- 「ログを保存…」で「簡易ログ」または「詳細ログ」を TXT・CSV 形式で保存できます。
- 「アップデートを確認…」で手動の更新確認ができます。

## 動作環境

macOS 13.0 以降。ビルドには Swift 5.9 以降に対応する Xcode が必要です。外部パッケージ依存はありません。

## 入手方法とビルド

Release はまだ公開されていません。現時点ではソースからビルドしてください。Release 公開後は GitHub Releases でアプリ入り ZIP を配布する予定です。GitHub が自動生成する `Source code (zip)` はソースのみです。

リポジトリのルートで実行します。生成物は一時領域に置きます。

```sh
swift test --scratch-path "$TMPDIR/fm-build"
xcodebuild -project FolderMerger.xcodeproj -scheme FolderMerger \
  -configuration Debug -derivedDataPath "$TMPDIR/fm-dd" build
open "$TMPDIR/fm-dd/Build/Products/Debug/Folder Merger.app"
```

Xcode で `FolderMerger.xcodeproj` を開き、FolderMerger スキームで Run することもできます。初回起動時に Gatekeeper がブロックした場合は[マニュアル](docs/user-guide-ja.md#入手起動と手動アップデート)を参照してください。

## 使い方

詳しい手順・設定・ログは[日本語マニュアル](docs/user-guide-ja.md)を参照してください。[設計・検証記録](docs/design.md)と[配布計画](docs/release.md)もあります。開発者向けの検証ルールは [AGENTS.md](AGENTS.md)、Claude Code の役割は [CLAUDE.md](CLAUDE.md) にあります。

## ライセンス

[MIT License](LICENSE) — Copyright (c) 2026 Kimiya Kitani
