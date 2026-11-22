import SwiftUI
import UIKit

func hex(_ v: Int, width: Int) -> String {
    let s = String(v, radix: 16, uppercase: true)
    return String(repeating: "0", count: max(0, width - s.count)) + s
}

/// バイト単位で書き換えられるHexエディタ
/// 操作: バイトをタップして選択 → 16進キーで入力 / 範囲選択・コピー・貼付・0埋め・挿入・削除・検索・文字列上書き
struct HexEditorView: View {
    let data: Data
    let commit: (Data) -> Void

    enum Prompt: String, Identifiable {
        case goto, find, text
        var id: String { rawValue }
    }

    private let perRow = 8
    private let pageSize = 2048

    @State private var page = 0
    @State private var selected = 0
    @State private var anchor: Int?
    @State private var rangeMode = false
    @State private var pending: UInt8?
    @State private var modified = Set<Int>()
    @State private var status = ""
    @State private var prompt: Prompt = .goto
    @State private var showPrompt = false
    @State private var field = ""

    private var pageCount: Int { max(1, (data.count + pageSize - 1) / pageSize) }
    private var offsetDigits: Int { max(4, String(data.count, radix: 16).count) }

    private var rowStarts: [Int] {
        let start = page * pageSize
        let end = min(data.count, start + pageSize)
        return start < end ? Array(stride(from: start, to: end, by: perRow)) : []
    }

    private var selectionRange: ClosedRange<Int>? {
        guard let a = anchor, !data.isEmpty else { return nil }
        let lo = min(a, selected, data.count - 1)
        let hi = min(max(a, selected), data.count - 1)
        return lo...hi
    }

    var body: some View {
        VStack(spacing: 8) {
            pager
            grid
            keypad
        }
        .alert(promptTitle, isPresented: $showPrompt) {
            TextField(promptHint, text: $field)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button("OK") { runPrompt() }
            Button("キャンセル", role: .cancel) {}
        }
    }

    private var promptTitle: String {
        switch prompt {
        case .goto: return "オフセットへ移動 (16進)"
        case .find: return "バイト列を検索 (16進)"
        case .text: return "文字列で上書き"
        }
    }

    private var promptHint: String {
        switch prompt {
        case .goto: return "例: 1F40"
        case .find: return "例: DE AD BE EF"
        case .text: return "上書きする文字列"
        }
    }

    // MARK: 表示

    private var pager: some View {
        HStack {
            Button("◀︎") { page = max(0, page - 1) }
                .glassButton()
                .disabled(page == 0)
            Spacer()
            Text("\(page + 1)/\(pageCount)  0x\(hex(page * pageSize, width: offsetDigits))")
                .font(.caption.monospaced())
            Spacer()
            Button("▶︎") { page = min(pageCount - 1, page + 1) }
                .glassButton()
                .disabled(page >= pageCount - 1)
        }
        .padding(8)
        .glassCapsule()
        .padding(.horizontal)
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
            .onChange(of: selected) { v in
                withAnimation { proxy.scrollTo(v / perRow * perRow, anchor: .center) }
            }
        }
    }

    private func row(_ start: Int) -> some View {
        HStack(spacing: 0) {
            Text(hex(start, width: offsetDigits) + "  ").foregroundStyle(.secondary)
            ForEach(0..<perRow, id: \.self) { c in
                cell(start + c)
            }
            Text("  " + ascii(start)).foregroundStyle(.secondary)
        }
        .font(.system(size: 13, design: .monospaced))
    }

    @ViewBuilder
    private func cell(_ i: Int) -> some View {
        if i < data.count {
            Text(cellText(i))
                .padding(.horizontal, 3)
                .padding(.vertical, 2)
                .background(cellColor(i), in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
                .onTapGesture { tap(i) }
        } else {
            Text("   ").padding(.horizontal, 3).padding(.vertical, 2)
        }
    }

    private func cellText(_ i: Int) -> String {
        if i == selected, let p = pending { return "\(hex(Int(p), width: 1))_" }
        return hex(Int(data[i]), width: 2)
    }

    private func cellColor(_ i: Int) -> Color {
        if i == selected { return Color.accentColor.opacity(0.5) }
        if let r = selectionRange, r.contains(i) { return Color.accentColor.opacity(0.2) }
        if modified.contains(i) { return Color.orange.opacity(0.3) }
        return Color.clear
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
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .multilineTextAlignment(.center)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 6) {
                ForEach(0..<16, id: \.self) { n in
                    Button { typeNibble(UInt8(n)) } label: {
                        Text(hex(n, width: 1)).frame(maxWidth: .infinity)
                    }
                    .glassButton()
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                tool("◀︎") { select(selected - 1) }
                tool("▶︎") { select(selected + 1) }
                tool(rangeMode ? "範囲:ON" : "範囲") { toggleRange() }
                tool("移動") { open(.goto) }
                tool("検索") { open(.find) }
                tool("文字") { open(.text) }
                tool("コピー") { copyRange() }
                tool("貼付") { pasteHex() }
                tool("0埋め") { fillRange() }
                tool("挿入") { insertByte() }
                tool("削除") { deleteBytes() }
            }
        }
        .padding(10)
        .glassCard(cornerRadius: 22)
        .padding(.horizontal, 10)
    }

    private func tool(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity)
        }
        .glassButton()
    }

    private var statusLine: String {
        guard !data.isEmpty, selected < data.count else { return "空のファイル（挿入でバイトを追加）" }
        let b = data[selected]
        var s = "0x\(hex(selected, width: offsetDigits)) = \(hex(Int(b), width: 2)) u8:\(b) i8:\(Int8(bitPattern: b))"
        if selected + 2 <= data.count {
            let v = UInt16(data[selected]) | (UInt16(data[selected + 1]) << 8)
            s += " u16LE:\(v)"
        }
        if selected + 4 <= data.count {
            var v: UInt32 = 0
            for k in 0..<4 { v |= UInt32(data[selected + k]) << (8 * UInt32(k)) }
            s += " u32LE:\(v) f32:\(Float(bitPattern: v))"
        }
        if let r = selectionRange, r.count > 1 { s += " 選択:\(r.count)B" }
        if let p = pending { s += " 入力中:\(hex(Int(p), width: 1))_" }
        if !status.isEmpty { s += "  \(status)" }
        return s
    }

    // MARK: 選択

    private func select(_ i: Int) {
        guard !data.isEmpty else { return }
        selected = min(max(0, i), data.count - 1)
        pending = nil
        status = ""
        page = selected / pageSize
    }

    private func tap(_ i: Int) {
        if rangeMode {
            if anchor == nil { anchor = selected }
            select(i)
        } else {
            anchor = nil
            select(i)
        }
    }

    private func toggleRange() {
        rangeMode.toggle()
        if !rangeMode { anchor = nil }
    }

    // MARK: 編集

    private func writeBytes(_ bytes: [UInt8], at start: Int) {
        guard !bytes.isEmpty else { return }
        var w = data
        for (k, b) in bytes.enumerated() {
            let i = start + k
            if i < w.count { w[i] = b } else { w.append(b) }
        }
        modified.formUnion(start..<(start + bytes.count))
        commit(w)
    }

    private func typeNibble(_ n: UInt8) {
        guard !data.isEmpty, selected < data.count else { return }
        if let hi = pending {
            writeBytes([(hi << 4) | n], at: selected)
            pending = nil
            if selected + 1 < data.count { select(selected + 1) }
        } else {
            pending = n
        }
    }

    private func insertByte() {
        var w = data
        w.insert(0, at: min(selected, w.count))
        modified.removeAll()
        anchor = nil
        commit(w)
    }

    private func deleteBytes() {
        guard !data.isEmpty, selected < data.count else { return }
        let r = selectionRange ?? (selected...selected)
        var w = data
        w.removeSubrange(r.lowerBound..<min(r.upperBound + 1, w.count))
        modified.removeAll()
        anchor = nil
        commit(w)
        selected = min(r.lowerBound, max(0, w.count - 1))
    }

    private func fillRange() {
        guard !data.isEmpty, selected < data.count else { return }
        let r = selectionRange ?? (selected...selected)
        writeBytes(Array(repeating: 0, count: r.count), at: r.lowerBound)
        status = "0で埋めました"
    }

    private func copyRange() {
        guard !data.isEmpty, selected < data.count else { return }
        let r = selectionRange ?? (selected...selected)
        let bytes = Array(data[r.lowerBound..<min(r.upperBound + 1, data.count)])
        UIPasteboard.general.string = bytes.map { hex(Int($0), width: 2) }.joined(separator: " ")
        status = "\(bytes.count)バイトをコピー"
    }

    private func pasteHex() {
        guard let s = UIPasteboard.general.string, let bytes = parseHex(s) else {
            status = "16進データがありません"
            return
        }
        writeBytes(bytes, at: selected)
        status = "\(bytes.count)バイト貼付"
    }

    private func open(_ p: Prompt) {
        prompt = p
        field = ""
        status = ""
        showPrompt = true
    }

    private func runPrompt() {
        switch prompt {
        case .goto:
            let t = field.lowercased().replacingOccurrences(of: "0x", with: "").trimmingCharacters(in: .whitespaces)
            if let v = Int(t, radix: 16), !data.isEmpty {
                select(min(v, data.count - 1))
            } else {
                status = "値が不正"
            }
        case .find:
            guard let pat = parseHex(field), !data.isEmpty else {
                status = "バイト列が不正"
                return
            }
            let needle = Data(pat)
            var found: Range<Int>? = nil
            if selected + 1 < data.count {
                found = data.range(of: needle, options: [], in: (selected + 1)..<data.count)
            }
            if found == nil {
                found = data.range(of: needle, options: [], in: 0..<data.count)
            }
            if let f = found {
                select(f.lowerBound)
                status = "見つかりました"
            } else {
                status = "見つかりません"
            }
        case .text:
            let bytes = Array(field.utf8)
            guard !bytes.isEmpty else { return }
            writeBytes(bytes, at: selected)
            status = "\(bytes.count)バイト上書き"
        }
    }

    private func parseHex(_ s: String) -> [UInt8]? {
        let t = s.lowercased().replacingOccurrences(of: "0x", with: "").filter { $0.isHexDigit }
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
