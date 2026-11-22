import SwiftUI

struct FolderView: View {
    let dir: URL
    @ObservedObject var ws: Workspace

    enum Prompt: String, Identifiable {
        case newFolder, newFile, rename
        var id: String { rawValue }
    }

    @State private var items: [URL] = []
    @State private var selection = Set<URL>()
    @State private var editMode: EditMode = .inactive
    @State private var query = ""
    @State private var searchContents = false
    @State private var hits: [SearchHit] = []
    @State private var showImporter = false
    @State private var importTarget: URL?
    @State private var prompt: Prompt = .newFolder
    @State private var showPrompt = false
    @State private var promptText = ""
    @State private var renameTarget: URL?
    @State private var deleting: [URL] = []
    @State private var showDelete = false
    @State private var moveTargets: [URL] = []
    @State private var moveMode = true
    @State private var showMove = false
    @State private var showDiff = false
    @State private var showExport = false

    var body: some View {
        Group {
            if query.isEmpty { browser } else { results }
        }
        .navigationTitle(dir == ws.root ? ws.title : dir.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "検索")
        .modifier(BackGuard(ws: ws, isRoot: dir == ws.root))
        .environment(\.editMode, $editMode)
        .toolbar { toolbarItems }
        .onAppear(perform: reload)
        .refreshable { reload() }
        .onChange(of: query) { _ in runSearch() }
        .onChange(of: searchContents) { _ in runSearch() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item]) { result in
            guard case .success(let src) = result else { return }
            if let t = importTarget {
                ws.replace(t, with: src)
            } else {
                ws.importFile(src, into: dir)
            }
            importTarget = nil
            reload()
        }
        .alert(promptTitle, isPresented: $showPrompt) {
            TextField("名前", text: $promptText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("OK") { commitPrompt() }
            Button("キャンセル", role: .cancel) {}
        }
        .confirmationDialog("削除しますか？", isPresented: $showDelete, titleVisibility: .visible) {
            Button("削除", role: .destructive) {
                deleting.forEach { ws.delete($0) }
                deleting = []
                selection = []
                reload()
            }
            Button("キャンセル", role: .cancel) {}
        }
        .confirmationDialog("書き出し方法", isPresented: $showExport, titleVisibility: .visible) {
            Button("そのまま書き出す") { ws.exportArchive(stripSignature: false) { ws.shareURL = $0 } }
            Button("署名を削除して書き出す") { ws.exportArchive(stripSignature: true) { ws.shareURL = $0 } }
            Button("キャンセル", role: .cancel) {}
        }
        .sheet(isPresented: $showMove) {
            FolderPicker(root: ws.root ?? dir, targets: moveTargets, move: moveMode, ws: ws) {
                selection = []
                reload()
            }
        }
        .sheet(isPresented: $showDiff) { DiffView(ws: ws) }
    }

    // MARK: 一覧

    private var browser: some View {
        List(selection: $selection) {
            ForEach(items, id: \.self) { url in
                row(url)
            }
            if items.isEmpty {
                Text("空のフォルダです").foregroundStyle(.secondary)
            }
        }
    }

    private var results: some View {
        List {
            Toggle("中身も検索（小さいテキスト）", isOn: $searchContents)
            ForEach(hits) { hit in
                NavigationLink {
                    if ws.isDir(hit.url) {
                        FolderView(dir: hit.url, ws: ws)
                    } else {
                        FileEditorView(url: hit.url)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hit.relative)
                        Text(hit.reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if hits.isEmpty {
                Text("見つかりません").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func row(_ url: URL) -> some View {
        let isDir = ws.isDir(url)
        NavigationLink {
            if isDir {
                FolderView(dir: url, ws: ws)
            } else {
                FileEditorView(url: url)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: ws.icon(url))
                    .frame(width: 24)
                    .foregroundStyle(isDir ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent)
                    if !isDir {
                        Text(ws.sizeText(url)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                deleting = [url]
                showDelete = true
            } label: { Label("削除", systemImage: "trash") }
            Button {
                renameTarget = url
                startPrompt(.rename, url.lastPathComponent)
            } label: { Label("名前変更", systemImage: "pencil") }
            .tint(.orange)
        }
        .contextMenu {
            if !isDir {
                Button {
                    importTarget = url
                    showImporter = true
                } label: { Label("差し替え", systemImage: "arrow.triangle.2.circlepath") }
                ShareLink(item: url) { Label("共有", systemImage: "square.and.arrow.up") }
                Button { duplicate(url) } label: { Label("複製", systemImage: "plus.square.on.square") }
            }
            Button {
                renameTarget = url
                startPrompt(.rename, url.lastPathComponent)
            } label: { Label("名前変更", systemImage: "pencil") }
            Button(role: .destructive) {
                deleting = [url]
                showDelete = true
            } label: { Label("削除", systemImage: "trash") }
        }
    }

    // MARK: ツールバー

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Button { startPrompt(.newFolder, "") } label: { Label("新規フォルダ", systemImage: "folder.badge.plus") }
                Button { startPrompt(.newFile, "new.txt") } label: { Label("新規テキストファイル", systemImage: "doc.badge.plus") }
                Button {
                    importTarget = nil
                    showImporter = true
                } label: { Label("ファイルを追加", systemImage: "square.and.arrow.down") }
                if ws.kind == .archive {
                    Divider()
                    Button { showDiff = true } label: { Label("変更内容", systemImage: "list.bullet.clipboard") }
                    Button { showExport = true } label: { Label("\(ws.archiveExt)として書き出し", systemImage: "square.and.arrow.up") }
                }
                Divider()
                Button { ws.pickerMode = .file } label: { Label("別のファイルを開く", systemImage: "doc") }
                Button { ws.pickerMode = .folder } label: { Label("別のフォルダを開く", systemImage: "folder") }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            EditButton()
        }
        ToolbarItemGroup(placement: .bottomBar) {
            if editMode.isEditing {
                Button {
                    moveTargets = Array(selection)
                    moveMode = false
                    showMove = true
                } label: { Label("コピー", systemImage: "doc.on.doc") }
                .disabled(selection.isEmpty)
                Button {
                    moveTargets = Array(selection)
                    moveMode = true
                    showMove = true
                } label: { Label("移動", systemImage: "folder") }
                .disabled(selection.isEmpty)
                Spacer()
                Button(role: .destructive) {
                    deleting = Array(selection)
                    showDelete = true
                } label: { Label("削除", systemImage: "trash") }
                .disabled(selection.isEmpty)
            }
        }
    }

    // MARK: 操作

    private var promptTitle: String {
        switch prompt {
        case .newFolder: return "新規フォルダ"
        case .newFile: return "新規テキストファイル"
        case .rename: return "名前変更"
        }
    }

    private func startPrompt(_ p: Prompt, _ text: String) {
        prompt = p
        promptText = text
        showPrompt = true
    }

    private func commitPrompt() {
        defer { reload() }
        let name = promptText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("/") else { return }
        switch prompt {
        case .rename:
            if let t = renameTarget { ws.rename(t, to: name) }
        case .newFolder:
            ws.makeFolder(in: dir, name: name)
        case .newFile:
            ws.makeFile(in: dir, name: name)
        }
    }

    private func duplicate(_ url: URL) {
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 2
        var dest = url
        repeat {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            dest = dir.appendingPathComponent(name)
            n += 1
        } while FileManager.default.fileExists(atPath: dest.path)
        ws.copyItem(url, to: dest)
        reload()
    }

    private func reload() {
        items = ws.list(dir)
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            hits = []
            return
        }
        ws.search(q, in: dir, contents: searchContents) { hits = $0 }
    }
}
