import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FolderMergerCore

private func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: Bundle.main.localizedString(forKey: key, value: nil, table: nil),
           locale: Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en"), arguments: arguments)
}

private func LC(_ key: String, _ count: Int) -> String {
    String(format: Bundle.main.localizedString(forKey: key, value: nil, table: nil),
           locale: Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en"), arguments: [count])
}

@main
struct FolderMergerApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
            .windowResizability(.contentMinSize)
    }
}

@MainActor
final class MergeModel: ObservableObject {
    @Published var inputs: [URL] = []
    @Published var destination: URL?
    @Published var name = L("Merged Folder")
    @Published var validation = L("Select input folders and a destination.")
    @Published var busy = false
    @Published var status = ""
    @Published var errorMessage = ""
    @Published var output: URL?
    @Published var completed = 0
    @Published var total = 0
    @Published var fileDates = UserDefaults.standard.object(forKey: "merge.preserveFileDates") as? Bool ?? true {
        didSet { UserDefaults.standard.set(fileDates, forKey: "merge.preserveFileDates") }
    }
    @Published var filePermissions = UserDefaults.standard.object(forKey: "merge.preserveFilePermissions") as? Bool ?? true {
        didSet { UserDefaults.standard.set(filePermissions, forKey: "merge.preserveFilePermissions") }
    }
    @Published var directoryDates = UserDefaults.standard.object(forKey: "merge.preserveDirectoryDates") as? Bool ?? false {
        didSet { UserDefaults.standard.set(directoryDates, forKey: "merge.preserveDirectoryDates") }
    }
    @Published var extendedAttributes = MergePreferences.preserveExtendedAttributes(in: .standard) {
        didSet { UserDefaults.standard.set(extendedAttributes, forKey: "merge.preserveExtendedAttributes") }
    }
    @Published var detailedLog = false
    @Published var snapshot: MergePlanDescription?
    @Published var logLines: [String] = []
    @Published var omittedLines = 0
    @Published var counters = MergeCounters()
    @Published var warnings: [AttributeWarning] = []
    @Published var currentItem = ""
    @Published var finalStatus = ""
    var options: MergeOptions {
        MergeOptions(fileDates: fileDates, filePermissions: filePermissions, directoryDates: directoryDates, extendedAttributes: extendedAttributes)
    }
    var nextPlan: MergePlanDescription? { request.map(MergePlanDescription.init) }
    func appendLogs(_ lines: [String], omitted: Int) {
        logLines.append(contentsOf: lines)
        omittedLines += omitted
        if logLines.count > 5000 {
            omittedLines += logLines.count - 5000
            logLines.removeFirst(logLines.count - 5000)
        }
    }
    private var generation = 0
    private var cancellation: CancellationToken?

    var request: MergeRequest? {
        destination.map { MergeRequest(inputs: inputs, destination: $0, name: name, options: options) }
    }
    func validate(clearOutput: Bool = true) {
        generation += 1
        let current = generation
        if clearOutput { output = nil }
        guard let request else { validation = L("Select a destination parent folder."); return }
        validation = L("Checking configuration…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let message: String
            do { try MergeEngine.validate(request); message = "" }
            catch { message = error.localizedDescription }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == current else { return }
                self.validation = message
            }
        }
    }
    func add(_ urls: [URL]) {
        guard !busy else { return }
        for url in urls {
            var directory: ObjCBool = false
            if url.isFileURL, FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue {
                inputs.append(url)
            } else { errorMessage = L("Only folders can be added: %@", String(describing: url.path)) }
        }
        validate()
    }
    func chooseInputs() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.prompt = L("Add")
        panel.message = L("Select input folders.")
        if panel.runModal() == .OK { add(panel.urls) }
    }
    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.prompt = L("Use as Destination")
        panel.message = L("Select a destination parent folder.")
        if panel.runModal() == .OK { destination = panel.url; validate() }
    }
    func start() {
        guard !busy, validation.isEmpty, let request else { return }
        busy = true; errorMessage = ""; output = nil; completed = 0; total = 0; status = L("Preparing…")
        snapshot = MergePlanDescription(request: request)
        logLines = []; omittedLines = 0; counters = MergeCounters(); warnings = []; finalStatus = ""; currentItem = ""
        let detailed = detailedLog
        let token = CancellationToken()
        cancellation = token
        DispatchQueue.global(qos: .userInitiated).async {
            // This buffer belongs to the serial worker; only batches cross to the main queue.
            var lines: [String] = []
            var omitted = 0
            var latest: MergeProgress?
            var latestEvent: MergeEvent?
            var lastFlush = Date.distantPast
            func flush(force: Bool = false) {
                guard force || Date().timeIntervalSince(lastFlush) >= 0.15 else { return }
                let batch = lines, dropped = omitted, p = latest, e = latestEvent
                lines.removeAll(keepingCapacity: true); omitted = 0; latest = nil; latestEvent = nil
                lastFlush = Date()
                DispatchQueue.main.async {
                    self.appendLogs(batch, omitted: dropped)
                    if let e { self.status = e.message; self.counters = e.counters }
                    if let p {
                        self.completed = p.completed; self.total = p.total; self.currentItem = p.currentItem
                        self.counters = p.counters
                        self.status = L("%@  Items: %@ / %@ · Copied: %@", p.phase, String(describing: p.completed), String(describing: p.total == 0 ? L("Unknown") : String(p.total)), String(describing: ByteCountFormatter.string(fromByteCount: p.bytesCopied, countStyle: .file)))
                    }
                }
            }
            let result = MergeEngine().run(request, cancellation: token, detailedLog: detailed, event: { e in
                if lines.count < 5000 { lines.append(e.line) } else { omitted += 1 }
                latestEvent = e
                flush()
            }, progress: { p in latest = p; flush() })
            flush(force: true)
            DispatchQueue.main.async {
                self.busy = false; self.cancellation = nil
                self.output = result.output; self.counters = result.counters; self.warnings = result.warnings
                self.finalStatus = result.status.label; self.status = result.status.label
                self.errorMessage = result.status == .failure ? (result.error?.localizedDescription ?? L("Failed")) : ""
                self.validate(clearOutput: false)
            }
        }
    }

    func cancel() { cancellation?.cancel(); status = L("Cancellation requested. Waiting for processing to stop and cleanup to finish…") }
}

struct ContentView: View {
    @StateObject private var model = MergeModel()
    @State private var dropTarget = false
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            Text("Folder Merger").font(.largeTitle)
            Text(L("Merge the contents of multiple folders into a new folder. Inputs remain unchanged."))
            GroupBox(L("Input folders (drop from Finder)")) {
                VStack(alignment: .leading) {
                    List {
                        ForEach(Array(model.inputs.enumerated()), id: \.offset) { index, url in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(url.lastPathComponent).bold()
                                    Text(url.path).font(.caption).textSelection(.enabled)
                                }
                                Spacer()
                                Button(L("Remove")) { model.inputs.remove(at: index); model.validate() }
                            }
                        }
                    }.frame(minHeight: 140)
                    Button(L("Add Input Folders…"), action: model.chooseInputs)
                }.padding(6)
            }
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(dropTarget ? Color.accentColor : .clear, lineWidth: 2))
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTarget) { providers in
                guard !model.busy else { return false }
                for provider in providers {
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        let url: URL?
                        if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                        else if let value = item as? URL { url = value }
                        else { url = nil }
                        if let url { DispatchQueue.main.async { model.add([url]) } }
                    }
                }
                return true
            }
            .disabled(model.busy)
            HStack {
                Button(L("Choose Destination Parent Folder…"), action: model.chooseDestination)
                Text(model.destination?.path ?? L("Not selected")).textSelection(.enabled)
            }.disabled(model.busy)
            TextField(L("Output folder name"), text: $model.name)
                .textFieldStyle(.roundedBorder).disabled(model.busy)
                .onChange(of: model.name) { _ in model.validate() }
            Text(L("Output: %@", model.request?.output.path ?? L("Select a destination")))
                .font(.callout).textSelection(.enabled)
            GroupBox(L("Preserve attributes")) {
                VStack(alignment: .leading) {
                    Toggle(L("Preserve file creation and modification dates"), isOn: $model.fileDates)
                    Text(L("Keeps the original file dates shown in Finder.")).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 8)
                    Toggle(L("Preserve file permissions"), isOn: $model.filePermissions)
                    Text(L("Keeps the original read, write, and execute permissions. Leave this on for normal use.")).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 8)
                    Toggle(L("Preserve folder creation and modification dates"), isOn: $model.directoryDates)
                    Text(L("Turn this on to keep the dates of the folders themselves. When folders at the same relative path are merged, the first one in the input list supplies the dates.")).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 8)
                    Toggle(L("Preserve Finder tags and other Mac metadata"), isOn: $model.extendedAttributes)
                    Text(L("Keeps Finder tags and additional data used by some Mac files. Leave this on for normal use.")).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 8)
                    DisclosureGroup(L("Details")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L("The technical names for Mac metadata are extended attributes and resource forks."))
                            Text(L("Shooting information (such as EXIF) embedded in Takeout photos and videos, and accompanying JSON files, are copied as file contents regardless of these settings."))
                            Text(L("If the destination does not support an attribute, the warning shows the affected path and attribute, and the result is “Completed with warnings”."))
                        }.font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.disabled(model.busy).frame(maxWidth: .infinity, alignment: .leading)
            }
            DisclosureGroup(L("Show Merge Plan")) {
                VStack(alignment: .leading, spacing: 6) {
                    if !model.busy {
                        Text(L("Next merge")).bold()
                        if let plan = model.nextPlan {
                            ForEach(Array(plan.steps.enumerated()), id: \.offset) { _, step in Text(step.text) }
                        }
                    }
                    if let plan = model.snapshot {
                        Text(model.busy ? L("Current merge (settings at start)") : L("Previous merge (settings at start)")).bold()
                        ForEach(Array(plan.steps.enumerated()), id: \.offset) { _, step in Text(step.text) }
                    }
                }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox(L("Activity Log")) {
                VStack(alignment: .leading) {
                    Toggle(L("Detailed per-file log"), isOn: $model.detailedLog).disabled(model.busy)
                    Text(model.counters.description)
                    Text(L("Current item: %@", model.currentItem))
                    if model.omittedLines > 0 { Text(LC("Omitted %lld lines", model.omittedLines)) }
                    ScrollView {
                        Text(model.logLines.joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 140)
                    if !model.warnings.isEmpty {
                        DisclosureGroup(L("Attribute Warnings (%lld)", model.warnings.count)) {
                            Text((model.warnings.prefix(1000).map { L("%@: %@: %@", $0.relativePath, $0.displayName, $0.reason) } + (model.warnings.count > 1000 ? [LC("%lld additional warnings", model.warnings.count - 1000)] : [])).joined(separator: "\n")).textSelection(.enabled)
                        }
                    }
                    Text(model.finalStatus).bold()
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if !model.validation.isEmpty { Text(model.validation).foregroundStyle(.secondary).textSelection(.enabled) }
            if model.busy {
                if model.total > 0 { ProgressView(value: Double(model.completed), total: Double(model.total)) }
                else { ProgressView().controlSize(.small) }
            }
            Text(model.status).textSelection(.enabled)
            if !model.errorMessage.isEmpty {
                ScrollView { Text(model.errorMessage).foregroundStyle(.red).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 130)
            }
            HStack {
                Button(L("Merge"), action: model.start).keyboardShortcut(.defaultAction)
                    .disabled(model.busy || !model.validation.isEmpty)
                if model.busy { Button(L("Cancel"), action: model.cancel) }
                if let output = model.output {
                    Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([output]) }
                }
                Spacer()
            }
        }.padding(22)
        }.frame(minWidth: 700, minHeight: 580)
    }
}
