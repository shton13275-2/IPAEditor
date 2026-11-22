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
                    VStack(spacing: 16) {
                        Image(systemName: "shippingbox")
                            .font(.system(size: 44))
                            .foregroundStyle(.secondary)
                        Text("ipaファイルを選択してください")
                        Button("ipaを開く") { picking = true }
                            .glassButton(prominent: true)
                            .controlSize(.large)
                        if !mgr.message.isEmpty {
                            Text(mgr.message)
                                .font(.footnote)
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .glassCapsule()
                        }
                    }
                    .padding(32)
                    .glassCard(cornerRadius: 32)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(GlassBackdrop())
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
                    NavigationLink {
                        FolderView(dir: url, mgr: mgr)
                    } label: {
                        Label(url.lastPathComponent, systemImage: "folder.fill")
                    }
                } else {
                    NavigationLink {
                        FileEditorView(url: url)
                    } label: {
                        Label(url.lastPathComponent, systemImage: "doc")
                    }
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

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
