# User guide (English)

[README](../README.md) · [日本語](user-guide-ja.md) · [Design (Japanese)](design.md) · [Release plan (Japanese)](release.md)

## 1. Overview and preparation

On macOS 13.0 or later, merge the contents of multiple folders directly into a chosen empty destination folder. Paths are relative to each input root; the root names are omitted. Inputs are never moved, renamed, or deleted, and existing items are never overwritten. Empty folders are included. No Release is available yet; [build from source](../README.md).

The app runs with your user permissions and App Sandbox disabled. macOS may require permission to access folders. Do not change inputs or the destination in other apps during a merge: no point-in-time snapshot of all inputs is created. Reading may update input access times.

The app follows the macOS system or per-app language setting. Japanese and English are supported; other languages fall back to English. There is no in-app language switch. File names and paths are not translated.

### Availability, first launch, and manual updates

Source publication uses [GitHub main](https://github.com/kimipooh/folder-merger-for-macos/tree/main). No Release is available yet. After publication, choose the app ZIP from [GitHub Releases](https://github.com/kimipooh/folder-merger-for-macos/releases). GitHub's automatically generated `Source code (zip)` contains source only, not the app.

The app has no Developer ID signature or Apple notarization. If first launch is blocked, try opening once → System Settings → Privacy & Security → Open Anyway. A new version may require approval again.

1. Select “Check for Updates…” in the Folder Merger menu. Only this action connects to GitHub. There are no launch-time or periodic checks, automatic downloads, installations, or restarts. The menu is disabled while checking. Merge state and progress are unaffected.
2. If “A new version is available. Current: <current> · Release: <release>” appears, select “Open Release Page” to open your default browser. Download and extract the app ZIP. “Cancel” leaves the page unopened.
3. Quit the old app, replace the `.app`, and launch the new version. The four attribute preferences and the same-path file rule persist between versions with the same bundle ID. Detailed logging starts off each time.

Other results mean the following. You can retry after completion or an error.

- “Your current version is up to date.”: the release is equal to or older than your version.
- “Could not retrieve a published release.”: HTTP 404, including when no first Release has been published. This does not mean you have the latest version.
- “GitHub rate limit reached. Please try again later.”: rate limiting.
- “A network error occurred. Please try again.”: connection failure or timeout.
- “The update server returned an invalid response.”: invalid response, tag, or URL. Drafts and prereleases are not accepted as formal releases.


## 2. Input folders and order

Choose multiple folders with “Add Input Folders…” or drop them from Finder onto “Input folders (drop from Finder)”. Full paths appear in the list. “Remove” removes an entry from the list without deleting source files.

Priority is from top to bottom in the displayed list. The selection panel appends its returned URLs in order. Multiple dropped folders are appended as asynchronous loads complete, so Finder selection order is not guaranteed. Check the list. There is no reorder control; remove entries and add them individually if priority matters. Folder attributes at the same relative path come from the first input; file attributes come from the file selected by the rule below.

Input roots cannot be symbolic links, duplicates, or nested within each other. Internal symbolic links (including broken links), FIFOs, sockets, and devices are unsupported. `.DS_Store` is excluded at every level; other hidden files are processed.

## 3. Destination, execution, and result

Use “Choose Destination Folder…” to choose an empty folder that neither overlaps nor contains/is contained by an input. Use the standard “New Folder” button to create one, and check the displayed path. Hidden files and subfolders count as contents; only `.DS_Store` is ignored and is neither read nor deleted. Merge is disabled until a valid empty folder is selected. Contents go directly into that folder, with no extra level or name field.

When configuration errors are resolved, press “Merge”. Inputs and destination cannot be edited during processing. Scanning, comparison, and copying run in the background. After completion, use “Show in Finder” to locate the output. Error text and paths can be selected and copied.

## 4. Examples

General example: inputs `Folder A/reports/a.txt` and `Folder B/reports/b.txt`, with an empty destination folder `Combined`, produce `Combined/reports/a.txt` and `Combined/reports/b.txt`. The input root names are omitted.

Google Takeout example: add already extracted parts named `Takeout`, `Takeout 2`, and `Takeout 3`. Choose an empty destination folder `Takeout` outside the inputs, without overlap or nesting. You need not rename the originals. All names below are synthetic.

```text
Takeout/Google Photos/Album/IMG.jpg
Takeout 2/Google Photos/Album/video.mp4
Takeout 3/Google Photos/Album/IMG.jpg.json
→ <destination>/Takeout/Google Photos/Album/IMG.jpg
→ <destination>/Takeout/Google Photos/Album/video.mp4
→ <destination>/Takeout/Google Photos/Album/IMG.jpg.json
```

The app does not extract ZIPs or correct shooting dates. Extract archives first.

## 5. Settings and attribute preservation

Open “Folder Merger → Settings…” or press `⌘,` (Japanese: “Folder Merger → 設定…”). The menu is supplied by the standard SwiftUI Settings scene; it has no custom entry in the app string catalog.

“Preserve attributes” contains four options. Initial defaults apply only to unsaved settings. Existing users keep their saved on or off values.

| Setting | Initial default | Information kept and when to use it |
| --- | --- | --- |
| Preserve file creation and modification dates | On | File creation and modification dates shown in Finder. Use when original dates matter. |
| Preserve file permissions | On | Read, write, and execute permission bits. Normally leave on. Does not include owner, group, or ACLs. |
| Preserve folder creation and modification dates | Off | Dates of folders themselves. Enable when folder dates should also be retained as records. |
| Preserve Finder tags and other Mac metadata | On | Extended attributes and resource forks of files and internal folders, including Finder tags. Normally leave on. |

Descriptions are always visible. Expand “Details” for technical names, Takeout contents, and unsupported-attribute warnings. A previously saved off value for Mac metadata is not automatically changed to the current on default. Reading an unsaved setting does not save it.

Folder attributes at the same relative path come from the first input; file attributes come from the selected file. Attributes are not combined. An identical later candidate is skipped and the current selection retains its attributes. The output root does not inherit input-root dates, attributes, or permissions. Internal folder attributes are applied after children have been created.

Disabled attributes are not explicitly copied from the source; OS creation values apply. Files with permissions disabled use 0666 filtered by umask; internal folders use 0777 filtered by umask. Access times, owners, groups, and ACLs are not copied from inputs. The chosen destination retains its own attributes, permissions, and ACL.

The four options are saved in UserDefaults and restored after restarting. “Detailed per-file log” under “Log” is not saved and is always off at launch. Settings remain editable during a merge, but changes to attributes and detailed logging apply to the next merge. The running merge keeps its settings captured at start.

“When different files have the same path” offers four choices:

- “Stop the merge”
- “Prefer the input folder added first” (default)
- “Prefer the input folder added later”
- “Prefer the file with the newer modification date”

The choice persists across launches; missing or invalid values use “Prefer the input folder added first”. With three or more inputs, compare the current selection with each next candidate in input-list order. Skip identical contents; apply the rule only to different contents. Newer-file priority compares input modification dates to nanosecond precision. Equal or incomparable dates stop the merge with the relative path, both inputs, and the reason. The rule is captured at start; changes during execution apply to the next merge.

## 6. File contents and Mac metadata

Regular file contents are copied unchanged using POSIX I/O in chunks of up to 1 MiB. The metadata option controls attached information such as Finder tags and resource forks. EXIF and similar data embedded in photos or videos are part of file contents and are copied regardless of that option. Google Takeout JSON is copied as separate files; its information is never written back into photos.

When extended attributes are enabled, `com.apple.quarantine` is also copied, so the output may retain quarantine treatment. Writing an OS-protected attribute such as `com.apple.rootless` may fail with EPERM and stop the merge. Only ENOTSUP/EOPNOTSUPP while applying an attribute at the destination becomes a warning and allows copying to continue. Other attribute errors, attribute read failures, and content I/O errors stop the merge.

## 7. Merge plan, progress, and activity log

Expand “Show Merge Plan” to inspect input order, final destination, attributes, merge rules, and copy method. It is initially collapsed. “Next merge” is shown separately from “Current merge (settings at start)” or “Previous merge (settings at start)”. Later setting changes do not rewrite the previous explanation.

“Activity Log” is visible by default and shows phases, current item, counts of copied files, identical files skipped, warnings and errors, and the final result. Scanning reports detected items; building reports completed / total items and copied bytes.

Enable “Detailed per-file log” under “Log” in Settings to add individual folder-creation, file-copy, and identical-file-skip events starting with the next merge. Events show time, relative path, supplying or skipped input, and file byte count. Each selection between different same-path files shows the relative path, selected input, rejected input, and rule even when detailed logging is off. Follow these decisions in order to identify the final selection across multiple inputs. Warnings, errors, cancellation, and completion also appear. A copied count increases when content copying finishes and remains as work performed even if a later attribute error causes the merge to fail.

The buffer and display each allow at most 5,000 lines and report omitted line counts. Updates arrive about every 150 ms, with an immediate final flush. Counts, final status, the warning array, and failure information are kept separately from this limit, but warning details display only the first 1,000 warnings and the remaining count. Select text to copy logs. Logs are not automatically saved to a file.

## 8. Conflicts, warnings, and cancellation

Folders at the same relative path are merged. Files are deduplicated only when sizes and every content byte match; modification dates alone are not used. Different contents use the selected priority rule. Canonically equivalent Unicode spellings (such as NFC/NFD) are measured per path component in temporary storage at the destination. They merge as one path only when the destination treats them as identical, retaining the first spelling; otherwise they remain separate. File/folder conflicts stop the merge. Case-only differences retain existing behavior: stop if the destination treats them as identical, otherwise save separate items. Review both relative paths and full input paths before deciding how to handle source data. There is no overwrite or automatic rename.

“Completed with warnings” means content copying finished but the destination did not support some attributes. Inspect the attribute warnings for paths, attributes, and reasons. “Failed” does not publish a completed output.

“Cancel” is checked at scan, comparison, copy-chunk, and other boundaries. Controls become available after processing stops, files close, and temporary data is cleaned up. Before publication starts, cancellation restores the empty destination (keeping `.DS_Store`). Once publication starts, cancellation is deferred until publication or rollback finishes.

The app builds in `.foldermerger-<UUID>.tmp` (mode 0700) inside the destination, rechecks emptiness, then publishes each top-level item with exclusive `RENAME_EXCL`. On failure it rolls published items back and cleans its temporary output. Items added by another process, `.DS_Store`, and the destination itself are kept. The destination inode, creation date, permissions, ACL, and Finder tags are preserved; input-root attributes are not applied to it. Cleanup failures report the temporary path. Forced termination or power loss may leave it behind. Quit the app and confirm processing has stopped before manually removing that specific temporary folder.

## Saving the activity log

After a run, choose **Save Log…**. The save panel provides **Log type** (**Summary log** / **Detailed log**) and **Format** (**TXT (UTF-8)** / **CSV (UTF-8 with BOM)**) independently. Defaults are Summary log and TXT. Suggested names include type and time, such as `FolderMerger-summary-log-20261112-120500.txt`. Changing type updates summary/detailed in the suggested name; changing format updates the extension. Custom filename stems are preserved. Standard replacement confirmation and save-error alerts apply. Saving is disabled before the first run and while running. Success, completion with warnings, failure, cancellation, and validation failure at run start support all four combinations.

**Detailed per-file log** controls screen display only. All events, including copies, folder creation and identical skips, are journaled even when it is off. Exports are independent of the screen's 5,000-line limit. Run conditions label this preference **Detailed per-file log (screen display)**.

Summary TXT has three sections: Final result → Copied files → Warnings and errors. The result shows status, finalized copy count, destination and finalization state. Each finalized output file has exactly one actual source → final destination line, using the final selected source for conflicts. Folders have no copy rows. Inputs, settings, selection history, identical skips and processing stages are available in the detailed log.

Summary CSV columns are Category, Source, Destination, Details, Protected columns. Categories include Final result, Copy, Warning, Error and Cancellation. Source and destination are absolute file paths.

Detailed TXT starts with Final result, then Inputs and settings, then Activity log (chronological). Detailed CSV columns are Time, Operation, Relative Path, Source / selected input, Destination / rejected input, Decision, Reason, Notes, Protected columns. Selection decisions name the selected and rejected input in Decision; Reason is one sentence without repeating the rule name. Final selection notes include scan completion and whether the result reached finalized output. Temporary copy rows explain that their destination is planned and still inside the temporary folder.

Both CSV types use UTF-8 with BOM, RFC 4180 and CRLF. Both TXT types use UTF-8 without BOM and LF; embedded CR/LF appear as `\r` / `\n`. Both CSV types prefix one apostrophe to values starting with `=`, `+`, `-`, `@`, TAB, CR, LF or fullwidth `＝`, `＋`, `－`, `＠`, including after Unicode whitespace, control or format characters. Existing leading apostrophes remain unchanged.

Protected columns lists modified columns in column order, separated by `;`. Summary identifiers are `category`, `source`, `destination`, `details`. Detailed identifiers are `time`, `action`, `relative_path`, `source`, `destination`, `decision`, `reason`, `notes`. Parse the CSV and remove exactly one leading apostrophe from listed columns only. An empty metadata field means no protection. Headings use the same check. Values originally starting with an apostrophe remain unchanged.

Successful runs show Output finalized. Failed/cancelled runs begin with Output is not finalized. Nothing was added to the destination. Their summary contains no copy entries. Cleanup or rollback failures instead report that failure and the remaining paths without claiming nothing was added. Warnings and errors identify what failed, the target and whether merging continued or stopped; system messages and internal attribute names are Notes.

Records are incrementally journaled outside inputs/output and streamed during export without retaining all events in memory. The temporary journal is removed at the next run and on exit. Recording errors do not stop merging; exports report Incomplete log and its reason. Logs include input paths; consider this when sharing. They are never automatically saved into input or merged output.

## Conflicting File Decisions

The numbered input list (1, 2, 3…) defines added-first / added-later order. The heading shows the current setting while idle and after completion. During execution, “Rule for this run:” shows the captured rule. Only when Settings differ from that captured rule does “The changed rule will apply to the next merge.” appear; it disappears when the run ends. “Rule used for this result:” identifies the rule actually used even after Settings change. The new default is “Prefer the input folder added first”; explicitly saved choices, including “Stop the merge”, remain unchanged. Launch does not write a default preference.

“Conflicting File Decisions” is separate from chronological Activity Log, even with detailed logging off. It counts relative paths with differing contents, excluding identical-only skips. Each entry shows the output spelling, final selected input, inputs rejected by a content-based decision, and rule. Inputs skipped because their contents are identical are excluded from rejected inputs and remain visible in the chronological skip records. The screen retains at most 1,000 entries and shows the remaining count; saved logs contain all entries. The unrun and active-run states show no output-finalization note. Successful output shows “Decisions reflected in finalized output.” Failure and cancellation show “Output is not finalized. These are selection decisions only.” An interrupted scan shows decisions so far with “Scan incomplete; decisions so far only”.

Create folder (temporary folder) and Copy (temporary folder) describe construction, before publication. Skip identical content describes deduplication. Same-name file selection (intermediate) records the selected and rejected inputs; Reason states the priority in one sentence and includes both input paths and timestamps for newer-file priority. Same-name file final selection names the final selected input and every rejected input. Notes show scan completion and whether the result reached finalized output. Finalize output means publication succeeded; Rollback means published items were returned to the temporary folder. Timestamps use ISO 8601, nine fractional digits and local UTC offset. Rejected inputs are joined with `; `; paths containing that separator are ambiguous within the field.
