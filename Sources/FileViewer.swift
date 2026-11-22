import SwiftUI
import UIKit

/// ファイルの種類に応じて編集・表示する画面
struct FileEditorView: View {
    let url: URL
    var isRoot = false

    @EnvironmentObject var ws: Workspace

    enum Kind {
        case image(UIImage), text, tree, binary, sqlite, media
    }
    enum Mode: Hashable { case primary, text, hex, preview, analysis }
    enum Target { case text, tree, data }

    struct EncOption: Identifiable {
        let name: String
        let enc: String.Encoding
        var id: String { name }
    }

    static let encodings: [EncOption] = [
        EncOption(name: "UTF-8", enc: .utf8),
        EncOption(name: "Shift_JIS", enc: .shiftJIS),
        EncOption(name: "EUC-JP", enc: .japaneseEUC),
        EncOption(name: "ISO-2022-JP", enc: .iso2022JP),
        EncOption(name: "UTF-16", enc: .utf16),
        EncOption(name: "Latin-1", enc: .isoLatin1),
    ]
    static let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "heic", "heif", "webp", "ico"]
    static let mediaExts: Set<String> = ["pdf", "mp4", "mov", "m4v", "mp3", "m4a", "wav", "aif", "aiff", "caf", "usdz", "usd", "usda", "usdc", "mpg", "mpeg"]
    static let maxTextBytes = 2_000_000

    @State private var kind: Kind = .binary
    @State private var mode: Mode = .primary
    @State private var lastMode: Mode = .primary
    @State private var loaded = false
    @State private var data = Data()
    @State private var text = ""
    @State private var encoding: String.Encoding = .utf8
    @State private var doc: Any = [String: Any]()
    @State private var treeFormat: TreeFormat = .json
    @State private var textDirty = false
    @State private var treeDirty = false
    @State private var dataDirty = false
    @State private var message = ""
    @State private var showLines = true
    @State private var showWrap = false
    @State private var showFind = false
    @State private var findText = ""
    @State private var replaceText = ""
    @State private var caseSensitive = true
    @State private var textHistory = UndoStack<String>()
    @State private var treeHistory = UndoStack<Any>()
    @State private var dataHistory = UndoStack<Data>()
    @State private var lastTextEdit = Date.distantPast

    private var isDirty: Bool { textDirty || treeDirty || dataDirty }

    private var isText: Bool {
        if case .text = kind { return true }
        return false
    }

    private var availableModes: [Mode] {
        switch kind {
        case .image: return [.primary, .hex, .analysis]
        case .text: return [.primary, .text, .hex, .analysis]
        case .tree: return [.primary, .text, .hex, .analysis]
        case .binary: return [.primary, .preview, .analysis]
        case .sqlite: return [.primary, .hex, .analysis]
        case .media: return [.primary, .hex, .analysis]
        }
    }

    private func label(_ m: Mode) -> String {
        switch m {
        case .primary:
            switch kind {
            case .image: return "画像"
            case .text: return "編集"
            case .tree: return "ツリー"
            case .binary: return "Hex"
            case .sqlite: return "DB"
            case .media: return "プレビュー"
            }
        case .text: return "テキスト"
        case .hex: return "Hex"
        case .preview: return "プレビュー"
        case .analysis: return "解析"
        }
    }

    // MARK: 画面構成

    var body: some View {
        content
            .safeAreaInset(edge: .bottom) { bottomBar }
            .navigationTitle(url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .modifier(BackGuard(ws: ws, isRoot: isRoot))
            .toolbar { toolbarItems }
            .sheet(isPresented: $showFind) { findSheet }
            .onAppear {
                if !loaded {
                    load()
                    loaded = true
                }
                ws.editorSave = { saveInternal() }
            }
            .onDisappear {
                ws.editorDirty = false
                ws.editorSave = nil
            }
            .onChange(of: isDirty) { ws.editorDirty = $0 }
            .onChange(of: mode) { switchMode(to: $0) }
    }

    private var bottomBar: some View {
        VStack(spacing: 6) {
            Picker("表示", selection: $mode) {
                ForEach(availableModes, id: \.self) { m in
                    Text(label(m)).tag(m)
                }
            }
            .pickerStyle(.segmented)
            Text(infoLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(12)
        .glassCard(cornerRadius: 24)
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private var infoLine: String {
        let ext = url.pathExtension.lowercased()
        var parts = [
            ext.isEmpty ? "拡張子なし" : ext,
            ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file),
        ]
        if case .image(let img) = kind {
            parts.append("\(Int(img.size.width))×\(Int(img.size.height))")
        }
        if isDirty { parts.append("● 未保存") }
        if !message.isEmpty { parts.append(message) }
        return parts.joined(separator: " ・ ")
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .primary: primary
        case .text: readOnlyText
        case .hex: HexEditorView(data: data, commit: commitData)
        case .preview: QuickLookView(url: url)
        case .analysis: AnalysisView(url: url, data: data)
        }
    }

    @ViewBuilder
    private var primary: some View {
        switch kind {
        case .image(let img):
            ImageZoomView(image: img)
        case .text:
            TextEditor(text: textBinding)
                .font(.system(.footnote, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        case .tree:
            TreeEditorView(doc: doc, commit: commitTree, isInfoPlist: url.lastPathComponent == "Info.plist")
        case .binary:
            HexEditorView(data: data, commit: commitData)
        case .sqlite:
            SQLiteBrowserView(url: url)
        case .media:
            QuickLookView(url: url)
        }
    }

    private var readOnlyText: some View {
        let lines = text.components(separatedBy: "\n")
        let axes: Axis.Set = showWrap ? .vertical : [.vertical, .horizontal]
        return ScrollView(axes) {
            HStack(alignment: .top, spacing: 10) {
                if showLines {
                    LazyVStack(alignment: .trailing, spacing: 0) {
                        ForEach(lines.indices, id: \.self) { i in
                            Text("\(i + 1)")
                        }
                    }
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
                }
                Text(text)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: showWrap ? .infinity : nil, alignment: .leading)
            }
            .padding(8)
        }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            Button { undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!canUndo)
            Button { redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!canRedo)
            Button("保存") { saveInternal() }
                .disabled(!isDirty)
            Menu {
                if isText {
                    Menu("文字コード") {
                        ForEach(FileEditorView.encodings) { opt in
                            Button(opt.name) { setEncoding(opt.enc) }
                        }
                    }
                    Button { showFind = true } label: { Label("検索と置換", systemImage: "magnifyingglass") }
                    Toggle("行番号", isOn: $showLines)
                    Toggle("折り返し", isOn: $showWrap)
                }
                ShareLink("共有", item: url)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private var findSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("検索", text: $findText)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("置換後", text: $replaceText)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Toggle("大文字小文字を区別", isOn: $caseSensitive)
                }
                Section {
                    Text("一致: \(matchCount)件")
                    Button("すべて置換") { replaceAll() }
                        .disabled(matchCount == 0)
                }
            }
            .navigationTitle("検索と置換")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { showFind = false }
                }
            }
        }
    }

    private var matchCount: Int {
        countMatches(text, findText)
    }

    private func countMatches(_ s: String, _ needle: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        let opts: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        var n = 0
        var idx = s.startIndex
        while idx < s.endIndex, let r = s.range(of: needle, options: opts, range: idx..<s.endIndex) {
            n += 1
            idx = r.upperBound
        }
        return n
    }

    private func replaceAll() {
        guard !findText.isEmpty else { return }
        let opts: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        textHistory.record(text)
        text = text.replacingOccurrences(of: findText, with: replaceText, options: opts)
        textDirty = true
    }

    // MARK: バインディング・履歴

    private var textBinding: Binding<String> {
        Binding(
            get: { text },
            set: { new in
                guard new != text else { return }
                if Date().timeIntervalSince(lastTextEdit) > 1 {
                    textHistory.record(text)
                }
                lastTextEdit = Date()
                text = new
                textDirty = true
                message = ""
            })
    }

    private func commitTree(_ new: Any) {
        treeHistory.record(doc)
        doc = new
        treeDirty = true
        message = ""
    }

    private func commitData(_ new: Data) {
        dataHistory.record(data)
        data = new
        dataDirty = true
        message = ""
    }

    private var editTarget: Target {
        guard mode == .primary else { return .data }
        switch kind {
        case .text: return .text
        case .tree: return .tree
        default: return .data
        }
    }

    private var canUndo: Bool {
        switch editTarget {
        case .text: return textHistory.canUndo
        case .tree: return treeHistory.canUndo
        case .data: return dataHistory.canUndo
        }
    }

    private var canRedo: Bool {
        switch editTarget {
        case .text: return textHistory.canRedo
        case .tree: return treeHistory.canRedo
        case .data: return dataHistory.canRedo
        }
    }

    private func undo() {
        switch editTarget {
        case .text:
            if let p = textHistory.undo(current: text) { text = p; textDirty = true }
        case .tree:
            if let p = treeHistory.undo(current: doc) { doc = p; treeDirty = true }
        case .data:
            if let p = dataHistory.undo(current: data) {
                data = p
                dataDirty = true
                if mode == .primary { classify() }
            }
        }
    }

    private func redo() {
        switch editTarget {
        case .text:
            if let p = textHistory.redo(current: text) { text = p; textDirty = true }
        case .tree:
            if let p = treeHistory.redo(current: doc) { doc = p; treeDirty = true }
        case .data:
            if let p = dataHistory.redo(current: data) {
                data = p
                dataDirty = true
                if mode == .primary { classify() }
            }
        }
    }

    // MARK: 読み込み・判定

    private func load() {
        do {
            data = try Data(contentsOf: url)
        } catch {
            data = Data()
            message = "読み込み失敗: \(error.localizedDescription)"
        }
        dataDirty = false
        classify()
    }

    /// data から表示用の状態を作り直す
    private func classify() {
        let ext = url.pathExtension.lowercased()
        textDirty = false
        treeDirty = false
        if Self.imageExts.contains(ext), let img = UIImage(data: data) {
            kind = .image(img)
            return
        }
        if data.starts(with: Array("SQLite format 3".utf8)) {
            kind = .sqlite
            return
        }
        if let t = TreeIO.decode(data, ext: ext) {
            kind = .tree
            doc = t.0
            treeFormat = t.1
            return
        }
        if Self.mediaExts.contains(ext) {
            kind = .media
            return
        }
        if data.count <= Self.maxTextBytes, !data.prefix(8000).contains(0) {
            for enc in [String.Encoding.utf8, .shiftJIS, .japaneseEUC] {
                if let s = String(data: data, encoding: enc) {
                    kind = .text
                    text = s
                    encoding = enc
                    return
                }
            }
        }
        kind = .binary
    }

    private func setEncoding(_ enc: String.Encoding) {
        guard commitEditors() else { return }
        guard let s = String(data: data, encoding: enc) else {
            message = "この文字コードでは読めません"
            return
        }
        encoding = enc
        text = s
        textDirty = false
        kind = .text
    }

    private func switchMode(to new: Mode) {
        guard new != lastMode else { return }
        guard commitEditors() else {
            mode = lastMode
            return
        }
        lastMode = new
        classify()
        if !availableModes.contains(new) {
            mode = .primary
            lastMode = .primary
        }
    }

    // MARK: 保存

    /// 編集中の内容を data に反映（失敗時は false）
    private func commitEditors() -> Bool {
        if textDirty {
            guard let d = text.data(using: encoding) else {
                message = "この文字コードで保存できない文字があります"
                return false
            }
            data = d
            textDirty = false
            dataDirty = true
        }
        if treeDirty {
            do {
                data = try TreeIO.encode(doc, treeFormat)
                treeDirty = false
                dataDirty = true
            } catch {
                message = "形式に変換できません: \(error.localizedDescription)"
                return false
            }
        }
        return true
    }

    @discardableResult
    private func saveInternal() -> Bool {
        guard commitEditors() else { return false }
        do {
            try data.write(to: url, options: .atomic)
            dataDirty = false
            message = "保存しました"
            return true
        } catch {
            message = "保存失敗: \(error.localizedDescription)"
            return false
        }
    }
}

/// ピンチで拡大できる画像ビューア
struct ImageZoomView: View {
    let image: UIImage
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width * scale)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { scale = min(max(1, lastScale * $0), 8) }
                            .onEnded { _ in lastScale = scale }
                    )
            }
        }
        .background(Color(white: 0.5, opacity: 0.15))
        .overlay(alignment: .topTrailing) {
            if scale > 1 {
                Button("リセット") {
                    scale = 1
                    lastScale = 1
                }
                .glassButton()
                .padding(12)
            }
        }
    }
}
