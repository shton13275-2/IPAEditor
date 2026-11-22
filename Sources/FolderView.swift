import SwiftUI

struct FolderView: View {
    let dir: URL
    @ObservedObject var ws: Workspace

    enum Prompt { case rename(URL), newFolder, newFile }

    @State private var items: [URL] = []
    @State private var showImporter = false
    @State private var importTarget: URL?      // nil = 追加, 値あり = 差し替え
    @State private var showPrompt = false
    @State private var prompt: Prompt = .newFolder
    @State private var input = ""
    @State private var deleting: URL?

    var body: some View {
        List {
            ForEach(items, id: \.self) { url in row(url) }
                .onDelete { idx in
                    if let i = idx.first { deleting = items[i] }
                }
            if items.isEmpty {
                Text("空のフォルダです").foregroundStyle(.secondary)
            }
        }
        .navigationTitle(dir == ws.root ? ws.title : dir.lastPathComponent)
        .onAppear { items = ws.list(dir) }
        .refreshable { items = ws.list(dir) }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        prompt = .newFolder; input = ""; showPrompt = true
                    } label: { Label("新規フォルダ", systemImage: "folder.badge.plus") }
                    Button {
                        prompt = .newFile; input = "new.txt"; showPrompt = true
                    } label: { Label("新規テキストファイル", systemImage: "doc.badge.plus") }
                    Button {
                        importTarget = nil; showImporter = true
                    } label: { Label("ファイルを追加", systemImage: "square.and.arrow.down") }
                    Divider()
                    if ws.kind == .archive {
                        Button {
                            ws.exportArchive { ws.shareURL = $0 }
                        } label: { Label("\(ws.archiveExt)に書き出し", systemImage: "square.and.arrow.up") }
                    }
                    Button { ws.pickerMode = .file } label: { Label("別のファイルを開く", systemImage: "doc") }
                    Button { ws.pickerMode = .folder } label: { Label("別のフォルダを開く", systemImage: "folder") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item]) { result in
            guard case .success(let src) = result else { return }
            if let t = importTarget { ws.replace(t, with: src) } else { ws.importFile(src, into: dir) }
            importTarget = nil
            items = ws.list(dir)
        }
        .alert(promptTitle, isPresented: $showPrompt) {
            TextField("名前", text: $input)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("OK") { commitPrompt() }
            Button("キャンセル", role: .cancel) {}
        }
        .confirmationDialog(
            "削除しますか?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible,
            presenting: deleting
        ) { url in
            Button("\(url.lastPathComponent) を削除", role: .destructive) {
                ws.delete(url)
                items = ws.list(dir)
            }
        }
    }

    @ViewBuilder
    private func row(_ url: URL) -> some View {
        let isDir = ws.isDir(url)
        NavigationLink {
            if isDir { FolderView(dir: url, ws: ws) } else { FileEditorView(url: url) }
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
        .contextMenu {
            if !isDir {
                Button {
                    importTarget = url; showImporter = true
                } label: { Label("差し替え", systemImage: "arrow.triangle.2.circlepath") }
                ShareLink(item: url)
            }
            Button {
                prompt = .rename(url); input = url.lastPathComponent; showPrompt = true
            } label: { Label("名前変更", systemImage: "pencil") }
            Button(role: .destructive) {
                deleting = url
            } label: { Label("削除", systemImage: "trash") }
        }
    }

    private var promptTitle: String {
        switch prompt {
        case .rename: return "名前変更"
        case .newFolder: return "新規フォルダ"
        case .newFile: return "新規テキストファイル"
        }
    }

    private func commitPrompt() {
        let name = input.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("/") else { return }
        switch prompt {
        case .rename(let url): ws.rename(url, to: name)
        case .newFolder: ws.makeFolder(in: dir, name: name)
        case .newFile: ws.makeFile(in: dir, name: name)
        }
        items = ws.list(dir)
    }
}
