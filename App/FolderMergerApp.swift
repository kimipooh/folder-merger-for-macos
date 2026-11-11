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
    private var generation = 0
    private var cancellation: CancellationToken?

    var request: MergeRequest? {
        destination.map { MergeRequest(inputs: inputs, destination: $0, name: name) }
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
        let token = CancellationToken()
        cancellation = token
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try MergeEngine().merge(request, cancellation: token) { p in
                    DispatchQueue.main.async {
                        self.completed = p.completed; self.total = p.total
                        self.status = "\(p.phase)  \(p.completed) / \(p.total == 0 ? "未確定" : String(p.total)) 件・コピー済み \(ByteCountFormatter.string(fromByteCount: p.bytesCopied, countStyle: .file))"
                    }
                }
            }
            DispatchQueue.main.async {
                self.busy = false; self.cancellation = nil
                switch result {
                case .success(let url): self.output = url; self.status = "統合が完了しました。"
                case .failure(let error):
                    if let mergeError = error as? MergeError, mergeError.kind == .cancelled {
                        self.errorMessage = ""
                        self.status = "キャンセルしました。一時データを片付けました。"
                    } else {
                        self.errorMessage = error.localizedDescription
                        self.status = "処理を終了しました。"
                    }
                }
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
        }.padding(22).frame(minWidth: 700, minHeight: 580)
    }
}
