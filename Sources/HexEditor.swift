import SwiftUI

func hex(_ v: Int, width: Int) -> String {
    let s = String(v, radix: 16, uppercase: true)
    return String(repeating: "0", count: max(0, width - s.count)) + s
}

/// バイト単位で書き換えられるHexエディタ
/// 使い方: バイトをタップして選択 → 下のキーパッドで16進を2桁入力(自動で次のバイトへ)
struct HexEditorView: View {
    @Binding var data: Data
    var onEdit: () -> Void

    private let perRow = 8
    private let pageSize = 2048

    enum PromptKind { case goto, find }

    @State private var page = 0
    @State private var selected = 0
    @State private var pending: UInt8?
    @State private var modified = Set<Int>()
    @State private var showPrompt = false
    @State private var prompt: PromptKind = .goto
    @State private var field = ""
    @State private var status = ""

    private var pageCount: Int { max(1, (data.count + pageSize - 1) / pageSize) }
    private var offsetDigits: Int { max(4, String(data.count, radix: 16).count) }

    var body: some View {
        VStack(spacing: 8) {
            pager
            grid
            keypad
        }
        .alert(prompt == .goto ? "オフセットへ移動(16進)" : "検索(16進バイト列)", isPresented: $showPrompt) {
            TextField(prompt == .goto ? "例: 1F40" : "例: DE AD BE EF", text: $field)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button("OK") { runPrompt() }
            Button("キャンセル", role: .cancel) {}
        }
    }

    // MARK: 部品

    private var pager: some View {
        HStack {
            Button("◀︎") { page = max(0, page - 1) }
                .glassButton().disabled(page == 0)
            Spacer()
            Text("\(page + 1)/\(pageCount)  0x\(hex(page * pageSize, width: offsetDigits))")
                .font(.caption.monospaced())
            Spacer()
            Button("▶︎") { page = min(pageCount - 1, page + 1) }
                .glassButton().disabled(page >= pageCount - 1)
        }
        .padding(8)
        .glassCapsule()
        .padding(.horizontal)
    }

    private var rowStarts: [Int] {
        let start = page * pageSize
        let end = min(data.count, start + pageSize)
        return stride(from: start, to: end, by: perRow).map { $0 }
    }

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if data.isEmpty {
                    Text("空のファイルです").foregroundStyle(.secondary).padding()
                }
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(rowStarts, id: \.self) { start in
                        row(start).id(start)
                    }
                }
                .padding(.horizontal, 8)
            }
            .onChange(of: selected) { sel in
                withAnimation { proxy.scrollTo(sel / perRow * perRow, anchor: .center) }
            }
        }
    }

    private func row(_ start: Int) -> some View {
        HStack(spacing: 0) {
            Text(hex(start, width: offsetDigits) + " ").foregroundStyle(.secondary)
            ForEach(0..<perRow, id: \.self) { c in cell(start + c) }
            Text(" " + ascii(start)).foregroundStyle(.secondary)
        }
        .font(.system(size: 13, design: .monospaced))
    }

    @ViewBuilder
    private func cell(_ i: Int) -> some View {
        if i < data.count {
            let isSel = (i == selected)
            Text(isSel && pending != nil ? hex(Int(pending!), width: 1) + "_" : hex(Int(data[i]), width: 2))
                .padding(.horizontal, 3)
                .padding(.vertical, 2)
                .background(
                    isSel ? Color.accentColor.opacity(0.45)
                          : (modified.contains(i) ? Color.orange.opacity(0.3) : Color.clear),
                    in: RoundedRectangle(cornerRadius: 4)
                )
                .contentShape(Rectangle())
                .onTapGesture { select(i) }
        } else {
            Text("  ").padding(.horizontal, 3).padding(.vertical, 2)
        }
    }

    private func ascii(_ start: Int) -> String {
        let end = min(start + perRow, data.count)
        return String((start..<end).map { i -> Character in
            let b = data[i]
            return (b >= 32 && b < 127) ? Character(UnicodeScalar(b)) : "."
        })
    }

    private var keypad: some View {
        VStack(spacing: 6) {
            Text(statusLine)
                .font(.caption.monospaced())
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 6) {
                ForEach(0..<16, id: \.self) { n in
                    Button { typeNibble(UInt8(n)) } label: {
                        Text(hex(n, width: 1)).frame(maxWidth: .infinity)
                    }
                    .glassButton()
                }
            }

            HStack(spacing: 6) {
                tool("◀︎") { select(selected - 1) }
                tool("▶︎") { select(selected + 1) }
                tool("移動") { prompt = .goto; field = ""; showPrompt = true }
                tool("検索") { prompt = .find; field = ""; showPrompt = true }
                tool("挿入") { insertByte() }
                tool("削除") { deleteByte() }
            }
        }
        .padding(10)
        .glassCard(cornerRadius: 22)
        .padding(.horizontal, 10)
    }

    private func tool(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).frame(maxWidth: .infinity) }
            .glassButton()
    }

    private var statusLine: String {
        guard !data.isEmpty, selected < data.count else { return "空のファイル  [挿入]でバイトを追加" }
        let b = data[selected]
        var s = "0x\(hex(selected, width: offsetDigits)) = \(hex(Int(b), width: 2))"
        if b >= 32 && b < 127 { s += " '\(Character(UnicodeScalar(b)))'" }
        if let p = pending { s += "  入力中: \(hex(Int(p), width: 1))_" }
        if !status.isEmpty { s += "  \(status)" }
        return s
    }

    // MARK: 操作

    private func select(_ i: Int) {
        guard i >= 0, i < data.count else { return }
        selected = i
        pending = nil
        status = ""
        page = i / pageSize
    }

    private func typeNibble(_ n: UInt8) {
        guard !data.isEmpty, selected < data.count else { return }
        if let hi = pending {
            data[selected] = (hi << 4) | n
            modified.insert(selected)
            pending = nil
            onEdit()
            if selected + 1 < data.count { select(selected + 1) }
        } else {
            pending = n
        }
    }

    private func insertByte() {
        let at = min(selected, data.count)
        data.insert(0, at: at)
        modified = [at]
        selected = at
        pending = nil
        status = ""
        page = at / pageSize
        onEdit()
    }

    private func deleteByte() {
        guard !data.isEmpty, selected < data.count else { return }
        data.remove(at: selected)
        modified.removeAll()
        selected = min(selected, max(0, data.count - 1))
        pending = nil
        status = ""
        page = min(selected / pageSize, pageCount - 1)
        onEdit()
    }

    private func runPrompt() {
        switch prompt {
        case .goto:
            let t = field.lowercased().replacingOccurrences(of: "0x", with: "")
                .trimmingCharacters(in: .whitespaces)
            if let v = Int(t, radix: 16), !data.isEmpty {
                select(min(v, data.count - 1))
            } else {
                status = "値が不正"
            }
        case .find:
            guard let pat = parseHex(field), !data.isEmpty else { status = "バイト列が不正"; return }
            let needle = Data(pat)
            var found: Range<Int>?
            if selected + 1 < data.count {
                found = data.range(of: needle, options: [], in: (selected + 1)..<data.count)
            }
            if found == nil { found = data.range(of: needle, options: [], in: 0..<data.count) }
            if let r = found {
                select(r.lowerBound)
                status = "見つかりました"
            } else {
                status = "見つかりません"
            }
        }
    }

    private func parseHex(_ s: String) -> [UInt8]? {
        let t = s.lowercased().replacingOccurrences(of: "0x", with: "")
            .filter { !$0.isWhitespace && $0 != "," }
        guard !t.isEmpty, t.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        var idx = t.startIndex
        while idx < t.endIndex {
            let next = t.index(idx, offsetBy: 2)
            guard let b = UInt8(t[idx..<next], radix: 16) else { return nil }
            out.append(b)
            idx = next
        }
        return out
    }
}
