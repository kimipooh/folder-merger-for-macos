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

macOS 13.0 以降、Apple Silicon（arm64）専用です。Intel Mac 用バイナリは配布しません。ビルドには Swift 5.9 以降に対応する Xcode が必要です。外部パッケージ依存はありません。

## 入手方法とビルド

[GitHub Releases の v1.0.0](https://github.com/kimipooh/folder-merger-for-macos/releases/tag/v1.0.0)（[最新版](https://github.com/kimipooh/folder-merger-for-macos/releases/latest)）から `Folder-Merger-v1.0.0-macOS-Apple-Silicon.zip` をダウンロードし、展開して `Folder Merger.app` を取り出します。GitHub が自動生成する `Source code (zip)` / `Source code (tar.gz)` はソースのみで、アプリを含みません。

Developer ID 署名・Apple 公証はありません。初回起動がブロックされた場合は、一度開こうとした後、「システム設定」→「プライバシーとセキュリティ」→「このまま開く」の順に進みます。新版でも再許可が必要な場合があります。

Folder Merger メニューの「アップデートを確認…」で更新の有無を確認し、GitHub Releases から手動でダウンロードします。旧版を終了してから `.app` を入れ替えます。自動更新はありません。

リポジトリのルートで実行します。生成物は一時領域に置きます。

```sh
swift test --package-path macos --scratch-path "$TMPDIR/fm-build"
xcodebuild -project macos/FolderMerger.xcodeproj -scheme FolderMerger \
  -configuration Release -arch arm64 -derivedDataPath "$TMPDIR/fm-rel-dd" build
open "$TMPDIR/fm-rel-dd/Build/Products/Release/Folder Merger.app"
```

Xcode で `macos/FolderMerger.xcodeproj` を開き、FolderMerger スキームで Run することもできます。初回起動時に Gatekeeper がブロックした場合は[マニュアル](docs/user-guide-ja.md#入手起動と手動アップデート)を参照してください。

## 使い方

詳しい手順・設定・ログは[日本語マニュアル](docs/user-guide-ja.md)を参照してください。[設計・検証記録](docs/design.md)と[配布計画](docs/release.md)もあります。開発者向けの検証ルールは [AGENTS.md](AGENTS.md)、Claude Code の役割は [CLAUDE.md](CLAUDE.md) にあります。

## ライセンス

[MIT License](LICENSE) — Copyright (c) 2026 Kimiya Kitani
