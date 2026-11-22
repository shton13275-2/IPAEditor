import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var mgr = IPAManager()
    @State private var picking = false
    @State private var shareURL: URL?

    var body: some View {
        NavigationStack {
            Group {
                if let dir = mgr.workDir {
                    FolderView(dir: dir, mgr: mgr)
                } else {
                    VStack(spacing: 12) {
                        Text("ipaファイルを選択してください")
                        Button("ipaを開く") { picking = true }
                            .buttonStyle(.borderedProminent)
                        Text(mgr.message).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(mgr.ipaName)
            .toolbar {
                if mgr.workDir != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("開く") { picking = true }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("書き出し") { shareURL = mgr.export() }
                    }
                }
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.data]) { result in
            if case .success(let url) = result { mgr.open(ipa: url) }
        }
        .sheet(item: $shareURL) { url in ShareSheet(url: url) }
    }
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }

struct FolderView: View {
    let dir: URL
    @ObservedObject var mgr: IPAManager
    @State private var items: [URL] = []
    @State private var replacing: URL?

    var body: some View {
        List {
            ForEach(items, id: \.self) { url in
                if mgr.isDir(url) {
                    NavigationLink(url.lastPathComponent) { FolderView(dir: url, mgr: mgr) }
                } else {
                    NavigationLink(url.lastPathComponent) { FileEditorView(url: url) }
                        .contextMenu {
                            Button("差し替え") { replacing = url }
                        }
                }
            }
            .onDelete { idx in
                idx.map { items[$0] }.forEach(mgr.delete)
                items = mgr.list(dir)
            }
        }
        .navigationTitle(dir.lastPathComponent)
        .onAppear { items = mgr.list(dir) }
        .fileImporter(isPresented: Binding(get: { replacing != nil }, set: { if !$0 { replacing = nil } }),
                      allowedContentTypes: [.data]) { result in
            if case .success(let src) = result, let t = replacing { mgr.replace(t, with: src) }
            replacing = nil
            items = mgr.list(dir)
        }
    }
}

struct FileEditorView: View {
    let url: URL
    @State private var text = ""
    @State private var isText = true

    var body: some View {
        Group {
            if isText {
                TextEditor(text: $text)
                    .font(.system(.footnote, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } else {
                Text("バイナリ/非テキストファイルです。長押しメニューの「差し替え」で置き換えてください。")
                    .padding()
            }
        }
        .navigationTitle(url.lastPathComponent)
        .toolbar {
            if isText {
                Button("保存") { try? text.write(to: url, atomically: true, encoding: .utf8) }
            }
        }
        .onAppear {
            if let s = try? String(contentsOf: url, encoding: .utf8) { text = s } else { isText = false }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
