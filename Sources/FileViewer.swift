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
    @State private var text = ""
    @State private var data = Data()
    @State private var info = ""
    @State private var message = ""

    private static let imageExts: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "heic", "heif", "webp", "ico"
    ]

    var body: some View {
        content
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 6) {
                    Picker("表示", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    Text(info + (message.isEmpty ? "" : "  ・  \(message)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .glassCard(cornerRadius: 24)
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
            }
            .navigationTitle(url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if canSave {
                    Button("保存") { save() }
                }
            }
            .onAppear(perform: load)
    }

    private var canSave: Bool {
        guard mode == .auto else { return false }
        switch kind {
        case .text, .plist: return true
        default: return false
        }
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .hex:
            HexView(data: data)
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
                TextEditor(text: $text)
                    .font(.system(.footnote, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            case .binary:
                HexView(data: data)
            }
        }
    }

    private func load() {
        data = (try? Data(contentsOf: url)) ?? Data()
        let ext = url.pathExtension.lowercased()
        let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        info = "\(ext.isEmpty ? "拡張子なし" : ext) ・ \(size)"

        if Self.imageExts.contains(ext), let img = UIImage(data: data) {
            kind = .image(img)
            info += " ・ \(Int(img.size.width))×\(Int(img.size.height))"
        } else if ext == "plist" || data.starts(with: Array("bplist".utf8)),
                  let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let xml = try? PropertyListSerialization.data(fromPropertyList: obj, format: .xml, options: 0),
                  let s = String(data: xml, encoding: .utf8) {
            kind = .plist
            text = s
        } else if !data.prefix(8000).contains(0), let s = String(data: data, encoding: .utf8) {
            kind = .text
            text = s
        } else {
            kind = .binary
        }
    }

    private func save() {
        do {
            switch kind {
            case .plist:
                // 入力されたXMLが正しいplistか検証してから保存(保存形式はXML)
                let d = Data(text.utf8)
                let obj = try PropertyListSerialization.propertyList(from: d, options: [], format: nil)
                let out = try PropertyListSerialization.data(fromPropertyList: obj, format: .xml, options: 0)
                try out.write(to: url)
                data = out
            default:
                try text.write(to: url, atomically: true, encoding: .utf8)
                data = Data(text.utf8)
            }
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

struct HexView: View {
    let data: Data
    private let pageSize = 4096
    @State private var page = 0

    private var pageCount: Int { max(1, (data.count + pageSize - 1) / pageSize) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("◀︎ 前") { page = max(0, page - 1) }
                    .glassButton().disabled(page == 0)
                Spacer()
                Text("\(page + 1) / \(pageCount)").font(.caption)
                Spacer()
                Button("次 ▶︎") { page = min(pageCount - 1, page + 1) }
                    .glassButton().disabled(page >= pageCount - 1)
            }
            .padding(8)
            .glassCapsule()
            .padding(.horizontal)
            .padding(.bottom, 4)

            ScrollView([.vertical, .horizontal]) {
                Text(dump(from: page * pageSize))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
            }
        }
    }

    private func dump(from start: Int) -> String {
        var out = ""
        let end = min(data.count, start + pageSize)
        var i = start
        while i < end {
            let line = data[i..<min(i + 16, end)]
            let hex = line.map { String(format: "%02X", $0) }.joined(separator: " ")
            let pad = String(repeating: " ", count: (16 - line.count) * 3)
            let ascii = String(line.map { ($0 >= 32 && $0 < 127) ? Character(UnicodeScalar($0)) : "." })
            out += String(format: "%08X  ", i) + hex + pad + "  " + ascii + "\n"
            i += 16
        }
        return out
    }
}
