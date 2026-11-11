import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FolderMergerCore

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
    @Published var name = "統合フォルダ"
    @Published var validation = "入力フォルダと保存先を選択してください。"
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
    @Published var extendedAttributes = UserDefaults.standard.object(forKey: "merge.preserveExtendedAttributes") as? Bool ?? false {
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
        guard let request else { validation = "保存先親フォルダを選択してください。"; return }
        validation = "構成を確認中…"
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
            } else { errorMessage = "フォルダ以外は追加できません: \(url.path)" }
        }
        validate()
    }
    func chooseInputs() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.prompt = "追加"
        if panel.runModal() == .OK { add(panel.urls) }
    }
    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.prompt = "保存先に設定"
        if panel.runModal() == .OK { destination = panel.url; validate() }
    }
    func start() {
        guard !busy, validation.isEmpty, let request else { return }
        busy = true; errorMessage = ""; output = nil; completed = 0; total = 0; status = "準備中…"
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
                        self.status = "\(p.phase)  \(p.completed) / \(p.total == 0 ? "未確定" : String(p.total)) 件・コピー済み \(ByteCountFormatter.string(fromByteCount: p.bytesCopied, countStyle: .file))"
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
                self.errorMessage = result.status == .failure ? (result.error?.localizedDescription ?? "失敗") : ""
                self.validate(clearOutput: false)
            }
        }
    }

    func cancel() { cancellation?.cancel(); status = "キャンセルを要求しました。処理停止と後片付けを待っています…" }
}

struct ContentView: View {
    @StateObject private var model = MergeModel()
    @State private var dropTarget = false
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            Text("Folder Merger").font(.largeTitle)
            Text("複数フォルダの中身を、新しいフォルダに統合します。入力は変更しません。")
            GroupBox("入力フォルダ（Finder からドロップできます）") {
                VStack(alignment: .leading) {
                    List {
                        ForEach(Array(model.inputs.enumerated()), id: \.offset) { index, url in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(url.lastPathComponent).bold()
                                    Text(url.path).font(.caption).textSelection(.enabled)
                                }
                                Spacer()
                                Button("削除") { model.inputs.remove(at: index); model.validate() }
                            }
                        }
                    }.frame(minHeight: 140)
                    Button("入力フォルダを追加…", action: model.chooseInputs)
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
                Button("保存先親フォルダを選択…", action: model.chooseDestination)
                Text(model.destination?.path ?? "未選択").textSelection(.enabled)
            }.disabled(model.busy)
            TextField("出力フォルダ名", text: $model.name)
                .textFieldStyle(.roundedBorder).disabled(model.busy)
                .onChange(of: model.name) { _ in model.validate() }
            Text("作成先: \(model.request?.output.path ?? "保存先を選択してください")")
                .font(.callout).textSelection(.enabled)
            GroupBox("属性の保持") {
                VStack(alignment: .leading) {
                    Toggle("ファイルの作成日・変更日を保持", isOn: $model.fileDates)
                    Toggle("ファイルのアクセス権を保持", isOn: $model.filePermissions)
                    Toggle("フォルダの作成日・変更日を保持", isOn: $model.directoryDates)
                    Toggle("拡張属性・リソースフォークを保持", isOn: $model.extendedAttributes)
                }.disabled(model.busy).frame(maxWidth: .infinity, alignment: .leading)
            }
            DisclosureGroup("処理内容を表示") {
                VStack(alignment: .leading, spacing: 6) {
                    if !model.busy {
                        Text("次回の実行予定").bold()
                        if let plan = model.nextPlan {
                            ForEach(Array(plan.steps.enumerated()), id: \.offset) { _, step in Text(step.text) }
                        }
                    }
                    if let plan = model.snapshot {
                        Text(model.busy ? "実行中の内容（開始時点）" : "前回の実行内容（開始時点）").bold()
                        ForEach(Array(plan.steps.enumerated()), id: \.offset) { _, step in Text(step.text) }
                    }
                }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("作業ログ") {
                VStack(alignment: .leading) {
                    Toggle("ファイルごとの詳細ログ", isOn: $model.detailedLog).disabled(model.busy)
                    Text(model.counters.description)
                    Text("現在の項目: \(model.currentItem)")
                    if model.omittedLines > 0 { Text("\(model.omittedLines) 行を省略") }
                    ScrollView {
                        Text(model.logLines.joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 140)
                    if !model.warnings.isEmpty {
                        DisclosureGroup("属性警告（全 \(model.warnings.count) 件）") {
                            Text((model.warnings.prefix(1000).map { "\($0.relativePath): \($0.attribute): \($0.reason)" } + (model.warnings.count > 1000 ? ["ほか \(model.warnings.count - 1000) 件"] : [])).joined(separator: "\n")).textSelection(.enabled)
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
                Button("統合", action: model.start).keyboardShortcut(.defaultAction)
                    .disabled(model.busy || !model.validation.isEmpty)
                if model.busy { Button("キャンセル", action: model.cancel) }
                if let output = model.output {
                    Button("Finder で表示") { NSWorkspace.shared.activateFileViewerSelecting([output]) }
                }
                Spacer()
            }
        }.padding(22)
        }.frame(minWidth: 700, minHeight: 580)
    }
}
