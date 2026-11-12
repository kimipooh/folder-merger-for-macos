# Folder Merger for macOS

English | [日本語](README-ja.md)

## Overview

Folder Merger is a Japanese/English macOS app that merges the contents of multiple folders directly into a chosen empty destination, preserving relative paths.

## Features

- Choose an empty destination directly with “Choose Destination Folder…”, or create one with “New Folder”. No extra folder level is added.
- Merge folders at the same relative path and keep one copy of identical files.
- For files with different contents at the same path, the default is “Prefer the input folder added first”. Settings also offer “Stop the merge”, “Prefer the input folder added later”, and “Prefer the file with the newer modification date”.
- Leave inputs unchanged and never overwrite existing items.
- Use “Save Log…” to save a “Summary log” or “Detailed log” in TXT or CSV format.
- Manually check for updates with “Check for Updates…”.

## Requirements

macOS 13.0 or later on Apple Silicon (arm64) only. No Intel Mac binary is distributed. Building requires Xcode with Swift 5.9 or later; there are no external package dependencies.

## Getting the app and building

Download `Folder-Merger-v1.0.0-macOS-Apple-Silicon.zip` from [GitHub Releases v1.0.0](https://github.com/kimipooh/folder-merger-for-macos/releases/tag/v1.0.0) ([latest release](https://github.com/kimipooh/folder-merger-for-macos/releases/latest)) and extract it to get `Folder Merger.app`. GitHub’s automatically generated `Source code (zip)` and `Source code (tar.gz)` contain source only and do not include the app.

The app has no Developer ID signature or Apple notarization. If first launch is blocked, try opening the app once, then go to System Settings → Privacy & Security → Open Anyway. A new version may require approval again.

Select “Check for Updates…” in the Folder Merger menu to check for a newer version, download it manually from GitHub Releases, quit the old app, and replace the `.app`. There are no automatic updates.

Run from the repository root. Build products stay in temporary storage:

```sh
swift test --package-path macos --scratch-path "$TMPDIR/fm-build"
xcodebuild -project macos/FolderMerger.xcodeproj -scheme FolderMerger \
  -configuration Release -arch arm64 -derivedDataPath "$TMPDIR/fm-rel-dd" build
open "$TMPDIR/fm-rel-dd/Build/Products/Release/Folder Merger.app"
```

Alternatively, open `macos/FolderMerger.xcodeproj` in Xcode and run the FolderMerger scheme. For first-launch instructions if Gatekeeper blocks the app, see the [user guide](docs/user-guide-en.md#availability-first-launch-and-manual-updates).

## Usage

See the [English user guide](docs/user-guide-en.md) for instructions, settings, and logs. The [design and validation record](docs/design.md) and [release plan](docs/release.md) are in Japanese. Developer verification rules are in [AGENTS.md](AGENTS.md); see also [Claude Code roles](CLAUDE.md).

## License

[MIT License](LICENSE) — Copyright (c) 2026 Kimiya Kitani
