import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var ws = Workspace()

    var body: some View {
        NavigationStack {
            Group {
                if let root = ws.root {
                    if ws.kind == .file {
                        FileEditorView(url: root)
                    } else {
                        FolderView(dir: root, ws: ws)
                    }
                } else {
                    home
                }
            }
            .navigationTitle(ws.root == nil ? "ファイルエディタ" : ws.title)
            .toolbar {
                if ws.root != nil {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button { ws.close() } label: { Image(systemName: "xmark") }
                    }
                }
            }
        }
        .id(ws.session)
        .overlay {
            if ws.busy {
                ZStack {
                    Color.black.opacity(0.15).ignoresSafeArea()
                    ProgressView("処理中…")
                        .padding(24)
                        .glassCard(cornerRadius: 24)
                }
            }
        }
        .fileImporter(
            isPresented: Binding(get: { ws.pickerMode != nil }, set: { if !$0 { ws.pickerMode = nil } }),
            allowedContentTypes: ws.pickerMode == .folder ? [.folder] : [.item]
        ) { result in
            switch result {
            case .success(let url): ws.open(url)
            case .failure(let e): ws.error = e.localizedDescription
            }
        }
        .sheet(item: $ws.shareURL) { url in ShareSheet(url: url) }
        .alert("エラー",
               isPresented: Binding(get: { ws.error != nil }, set: { if !$0 { ws.error = nil } })) {
            Button("OK") {}
        } message: {
            Text(ws.error ?? "")
        }
    }

    private var home: some View {
        VStack(spacing: 16) {
            Image(systemName: "shippingbox")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Button("ファイルを開く") { ws.pickerMode = .file }
                .glassButton(prominent: true)
                .controlSize(.large)
            Button("フォルダを開く") { ws.pickerMode = .folder }
                .glassButton()
                .controlSize(.large)
            Text("ipa / zip は展開して編集・書き出しできます。\nそれ以外のファイルやフォルダは、そのまま編集します。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .glassCard(cornerRadius: 32)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GlassBackdrop())
    }
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
