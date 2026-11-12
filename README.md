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

macOS 13.0 or later. Building requires Xcode with Swift 5.9 or later; there are no external package dependencies.

## Getting the app and building

No Release is available yet. For now, build from source. Once a Release is published, an app ZIP is planned for GitHub Releases; GitHub's generated `Source code (zip)` contains only source.

Run from the repository root. Build products stay in temporary storage:

```sh
swift test --scratch-path "$TMPDIR/fm-build"
xcodebuild -project FolderMerger.xcodeproj -scheme FolderMerger \
  -configuration Debug -derivedDataPath "$TMPDIR/fm-dd" build
open "$TMPDIR/fm-dd/Build/Products/Debug/Folder Merger.app"
```

Alternatively, open `FolderMerger.xcodeproj` in Xcode and run the FolderMerger scheme. For first-launch instructions if Gatekeeper blocks the app, see the [user guide](docs/user-guide-en.md#availability-first-launch-and-manual-updates).

## Usage

See the [English user guide](docs/user-guide-en.md) for instructions, settings, and logs. The [design and validation record](docs/design.md) and [release plan](docs/release.md) are in Japanese. Developer verification rules are in [AGENTS.md](AGENTS.md); see also [Claude Code roles](CLAUDE.md).

## License

[MIT License](LICENSE) — Copyright (c) 2026 Kimiya Kitani
