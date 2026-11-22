import SwiftUI

struct FileEditorView: View {
    let url: URL

    enum Mode: String, CaseIterable, Identifiable {
        case auto = "自動", text = "テキスト", hex = "Hex"
        var id: String { rawValue }
    }
    enum Kind { case image(UIImage), text, plist, binary }

    @State private var kind: Kind = .binary
    @State private var mode: Mode = .auto
    @State private var lastMode: Mode = .auto
    @State private var text = ""
    @State private var data = Data()
    @State private var message = ""
    @State private var textDirty = false        // テキスト編集が未反映
    @State private var dirty = false            // ファイルと内容が違う(未保存)
    @State private var needsReclassify = false  // Hexで変更したので再判定が必要
    @State private var plistFormat = PropertyListSerialization.PropertyListFormat.xml

    private static let imageExts: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "heic", "heif", "webp", "ico"
    ]
    private static let maxTextBytes = 2_000_000

    var body: some View {
        content
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 6) {
                    Picker("表示", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
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
            .navigationTitle(url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    ShareLink(item: url)
                    Button("保存") { save() }
                        .disabled(!(dirty || textDirty))
                }
            }
            .onAppear(perform: load)
            .onChange(of: mode) { new in
                guard new != lastMode else { return }
                if lastMode == .auto && textDirty {
                    if !commitText() { mode = lastMode; return }
                }
                if new == .auto && needsReclassify {
                    classify()
                    needsReclassify = false
                }
                lastMode = new
            }
    }

    // MARK: 表示

    private var infoLine: String {
        let ext = url.pathExtension.lowercased()
        var parts = [
            ext.isEmpty ? "拡張子なし" : ext,
            ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        ]
        if case .image(let img) = kind { parts.append("\(Int(img.size.width))×\(Int(img.size.height))") }
        if dirty || textDirty { parts.append("● 未保存") }
        if !message.isEmpty { parts.append(message) }
        return parts.joined(separator: " ・ ")
    }

    private var textBinding: Binding<String> {
        Binding(get: { text }, set: { text = $0; textDirty = true; message = "" })
    }

    private var hexEditor: some View {
        HexEditorView(data: $data) {
            dirty = true
            needsReclassify = true
            message = ""
        }
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .hex:
            hexEditor
        case .text:
            ScrollView {
                Text(String(decoding: data.prefix(200_000), as: UTF8.self))
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
        case .auto:
            switch kind {
            case .image(let img):
                ImageZoomView(image: img)
            case .text, .plist:
                TextEditor(text: textBinding)
                    .font(.system(.footnote, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            case .binary:
                hexEditor
            }
        }
    }

    // MARK: 読み込み・判定・保存

    private func load() {
        do {
            data = try Data(contentsOf: url)
        } catch {
            data = Data()
            message = "読み込み失敗: \(error.localizedDescription)"
        }
        classify()
    }

    private func classify() {
        let ext = url.pathExtension.lowercased()
        var fmt = PropertyListSerialization.PropertyListFormat.xml

        if Self.imageExts.contains(ext), let img = UIImage(data: data) {
            kind = .image(img)
        } else if ext == "plist" || data.starts(with: Array("bplist".utf8)),
                  let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: &fmt),
                  let xml = try? PropertyListSerialization.data(fromPropertyList: obj, format: .xml, options: 0),
                  let s = String(data: xml, encoding: .utf8) {
            kind = .plist
            plistFormat = fmt
            text = s
            textDirty = false
        } else if data.count <= Self.maxTextBytes,
                  !data.prefix(8000).contains(0),
                  let s = String(data: data, encoding: .utf8) {
            kind = .text
            text = s
            textDirty = false
        } else {
            kind = .binary
        }
    }

    /// テキスト編集を data に反映(plist は元の形式で書き戻す)
    private func commitText() -> Bool {
        guard textDirty else { return true }
        switch kind {
        case .plist:
            do {
                let obj = try PropertyListSerialization.propertyList(from: Data(text.utf8), options: [], format: nil)
                data = try PropertyListSerialization.data(fromPropertyList: obj, format: plistFormat, options: 0)
            } catch {
                message = "plistの形式が不正です"
                return false
            }
        case .text:
            data = Data(text.utf8)
        default:
            break
        }
        textDirty = false
        dirty = true
        return true
    }

    private func save() {
        guard commitText() else { return }
        do {
            try data.write(to: url)
            dirty = false
            message = "保存しました"
        } catch {
            message = "保存失敗: \(error.localizedDescription)"
        }
    }
}

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
                Button("リセット") { scale = 1; lastScale = 1 }
                    .glassButton()
                    .padding(12)
            }
        }
    }
}
