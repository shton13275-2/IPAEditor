import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var ws: Workspace
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if sizeClass == .regular {
                // iPad: 2カラム（サイドバー + 詳細）
                NavigationSplitView {
                    sidebar
                } detail: {
                    NavigationStack { workspaceOrHome }
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                // iPhone: サイドバーと作業画面を同じスタックで切り替える
                // （NavigationSplitView は選択がないと詳細を表示しないため使わない）
                NavigationStack {
                    if ws.root != nil {
                        workspaceOrHome
                    } else {
                        sidebar
                    }
                }
            }
        }
        .overlay { busyOverlay }
        .fileImporter(isPresented: pickerBinding,
                      allowedContentTypes: ws.pickerMode == .folder ? [.folder] : [.item]) { result in
            switch result {
            case .success(let url): ws.requestLeave { ws.open(url) }
            case .failure(let e): ws.error = e.localizedDescription
            }
        }
        .sheet(item: $ws.shareURL) { url in ShareSheet(url: url) }
        .alert("エラー", isPresented: errorBinding) {
            Button("OK") {}
        } message: {
            Text(ws.error ?? "")
        }
        .confirmationDialog(leaveTitle, isPresented: leaveBinding, titleVisibility: .visible) {
            leaveButtons
        }
    }

    // MARK: 画面

    @ViewBuilder
    private var workspaceOrHome: some View {
        if let root = ws.root {
            workspace(root).id(ws.session)
        } else {
            home
        }
    }

    @ViewBuilder
    private func workspace(_ root: URL) -> some View {
        if ws.kind == .file {
            FileEditorView(url: root, isRoot: true)
        } else {
            FolderView(dir: root, ws: ws)
        }
    }

    private var sidebar: some View {
        List {
            Section("開く") {
                Button { ws.pickerMode = .file } label: { Label("ファイルを開く", systemImage: "doc") }
                Button { ws.pickerMode = .folder } label: { Label("フォルダを開く", systemImage: "folder") }
            }
            Section("最近使った項目") {
                if ws.recents.isEmpty {
                    Text("まだありません").foregroundStyle(.secondary)
                }
                ForEach(ws.recents) { item in
                    Button { ws.openRecent(item) } label: {
                        Label(item.name, systemImage: item.isDirectory ? "folder" : "doc")
                    }
                }
            }
        }
        .navigationTitle("ファイルエディタ")
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
            Text("ipa / zip は展開して編集・書き出しできます。\nそれ以外のファイルやフォルダも直接編集できます。")
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

    @ViewBuilder
    private var busyOverlay: some View {
        if ws.busy {
            ZStack {
                Color.black.opacity(0.2).ignoresSafeArea()
                VStack(spacing: 12) {
                    if let p = ws.progress {
                        ProgressView(value: p)
                    } else {
                        ProgressView()
                    }
                    Text("処理中…")
                    Button("キャンセル") { ws.cancelBusy() }
                        .glassButton()
                }
                .padding(24)
                .glassCard(cornerRadius: 24)
            }
        }
    }

    // MARK: 未保存の確認

    private var leaveTitle: String {
        switch ws.pendingLeave?.kind {
        case .unexportedArchive: return "書き出していない変更があります"
        default: return "未保存の変更があります"
        }
    }

    @ViewBuilder
    private var leaveButtons: some View {
        if let req = ws.pendingLeave {
            switch req.kind {
            case .unsavedEditor:
                Button("保存して戻る") {
                    if ws.editorSave?() == true { finish(req) }
                }
                Button("破棄して戻る", role: .destructive) {
                    ws.editorDirty = false
                    finish(req)
                }
            case .unexportedArchive:
                Button("書き出して共有") {
                    ws.pendingLeave = nil
                    ws.exportArchive(stripSignature: false) { ws.shareURL = $0 }
                }
                Button("変更を破棄して閉じる", role: .destructive) { finish(req) }
            }
        }
        Button("キャンセル", role: .cancel) { ws.pendingLeave = nil }
    }

    private func finish(_ req: LeaveRequest) {
        ws.pendingLeave = nil
        req.action()
    }

    // MARK: バインディング

    private var pickerBinding: Binding<Bool> {
        Binding(get: { ws.pickerMode != nil }, set: { if !$0 { ws.pickerMode = nil } })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { ws.error != nil }, set: { if !$0 { ws.error = nil } })
    }

    private var leaveBinding: Binding<Bool> {
        Binding(get: { ws.pendingLeave != nil }, set: { if !$0 { ws.pendingLeave = nil } })
    }
}

/// 戻る/閉じるボタン。未保存の変更があれば確認を出す
struct BackGuard: ViewModifier {
    @ObservedObject var ws: Workspace
    let isRoot: Bool
    @Environment(\.dismiss) var dismiss

    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        if isRoot {
                            ws.requestLeave { ws.close() }
                        } else if ws.editorDirty {
                            let back = dismiss
                            ws.pendingLeave = LeaveRequest(kind: .unsavedEditor) { back() }
                        } else {
                            dismiss()
                        }
                    } label: {
                        Label(isRoot ? "閉じる" : "戻る", systemImage: isRoot ? "xmark" : "chevron.backward")
                    }
                }
            }
    }
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }
