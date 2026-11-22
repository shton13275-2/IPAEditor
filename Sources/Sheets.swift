import SwiftUI

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// 展開時からの変更一覧（個別・一括で元に戻せる）
struct DiffView: View {
    @ObservedObject var ws: Workspace
    @Environment(\.dismiss) var dismiss
    @State private var changes: [FileChange] = []
    @State private var loading = true

    var body: some View {
        NavigationStack {
            List {
                if loading { ProgressView() }
                ForEach(changes) { c in
                    HStack {
                        Text(c.label)
                            .font(.caption.bold())
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(tint(c).opacity(0.2), in: Capsule())
                        Text(c.path).font(.footnote.monospaced()).lineLimit(2)
                        Spacer()
                        Button("戻す") {
                            ws.restore(c)
                            reload()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                if !loading && changes.isEmpty {
                    Text("変更はありません").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("変更内容")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("すべて戻す") {
                        changes.forEach { ws.restore($0) }
                        reload()
                    }
                    .disabled(changes.isEmpty)
                }
            }
            .onAppear(perform: reload)
        }
    }

    private func reload() {
        loading = true
        ws.computeChanges { result in
            changes = result
            loading = false
        }
    }

    private func tint(_ c: FileChange) -> Color {
        switch c {
        case .modified: return .orange
        case .added: return .green
        case .removed: return .red
        }
    }
}

/// ワークスペース内の移動先・コピー先を選ぶ
struct FolderPicker: View {
    let root: URL
    let targets: [URL]
    let move: Bool
    @ObservedObject var ws: Workspace
    let onDone: () -> Void
    @Environment(\.dismiss) var dismiss
    @State private var folders: [URL] = []

    var body: some View {
        NavigationStack {
            List(folders, id: \.self) { f in
                Button {
                    ws.transfer(targets, to: f, move: move)
                    onDone()
                    dismiss()
                } label: {
                    Label(relative(f), systemImage: "folder")
                }
            }
            .navigationTitle(move ? "移動先を選択" : "コピー先を選択")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
            }
            .onAppear { folders = ws.allFolders(under: root) }
        }
    }

    private func relative(_ f: URL) -> String {
        let r = String(f.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count))
        return r.isEmpty ? "/" : r
    }
}
