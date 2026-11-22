import SwiftUI

enum TreeFormat {
    case plist(PropertyListSerialization.PropertyListFormat)
    case json
}

enum PathElem: Hashable {
    case key(String)
    case index(Int)
}

/// plist / JSON の読み書き
enum TreeIO {
    static func decode(_ d: Data, ext: String) -> (Any, TreeFormat)? {
        if ext == "json" {
            guard let o = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]),
                  o is [String: Any] || o is [Any] else { return nil }
            return (o, .json)
        }
        if ext == "plist" || d.starts(with: Array("bplist".utf8)) || d.starts(with: Array("<?xml".utf8)) {
            var fmt = PropertyListSerialization.PropertyListFormat.xml
            guard let o = try? PropertyListSerialization.propertyList(from: d, options: [], format: &fmt),
                  o is [String: Any] || o is [Any] else { return nil }
            return (o, .plist(fmt))
        }
        return nil
    }

    static func encode(_ obj: Any, _ f: TreeFormat) throws -> Data {
        switch f {
        case .plist(let pf):
            return try PropertyListSerialization.data(fromPropertyList: obj, format: pf, options: 0)
        case .json:
            return try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        }
    }
}

/// ネスト構造の参照・変更
enum TreeOps {
    static func isBool(_ v: Any) -> Bool {
        guard let n = v as? NSNumber else { return false }
        return CFGetTypeID(n) == CFBooleanGetTypeID()
    }

    static func editable(_ v: Any) -> Bool {
        v is String || v is NSNumber
    }

    static func scalar(_ v: Any) -> String {
        if let s = v as? String { return s }
        if isBool(v) { return (v as? Bool) == true ? "true" : "false" }
        if let d = v as? Data { return "<データ \(d.count) バイト>" }
        if let dt = v as? Date { return ISO8601DateFormatter().string(from: dt) }
        return "\(v)"
    }

    static func value(_ node: Any, _ path: [PathElem]) -> Any? {
        var cur: Any? = node
        for p in path {
            switch p {
            case .key(let k):
                if let d = cur as? [String: Any] { cur = d[k] } else { cur = nil }
            case .index(let i):
                if let a = cur as? [Any], i < a.count { cur = a[i] } else { cur = nil }
            }
        }
        return cur
    }

    /// path の位置を value に置き換える（value が nil なら削除）
    static func set(_ node: Any, _ path: ArraySlice<PathElem>, to value: Any?) -> Any {
        guard let first = path.first else { return value ?? node }
        let rest = path.dropFirst()
        switch first {
        case .key(let k):
            var d = (node as? [String: Any]) ?? [:]
            if rest.isEmpty {
                d[k] = value
            } else if let child = d[k] {
                d[k] = set(child, rest, to: value)
            }
            return d
        case .index(let i):
            var a = (node as? [Any]) ?? []
            guard a.indices.contains(i) else { return a }
            if rest.isEmpty {
                if let value { a[i] = value } else { a.remove(at: i) }
            } else {
                a[i] = set(a[i], rest, to: value)
            }
            return a
        }
    }

    /// 入力文字列を元の型に合わせて変換
    static func parse(_ s: String, like old: Any) -> Any? {
        if old is String { return s }
        if isBool(old) {
            switch s.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        if old is NSNumber {
            if let i = Int(s) { return i }
            if let d = Double(s) { return d }
        }
        return nil
    }
}

struct TreeNode: Identifiable {
    let id: String
    let path: [PathElem]
    let label: String
    let preview: String
    let isBool: Bool
    let isContainer: Bool
    let children: [TreeNode]?

    static func build(_ v: Any, path: [PathElem] = [], label: String = "root") -> TreeNode {
        let id = path.map { "\($0)" }.joined(separator: "/")
        if let d = v as? [String: Any] {
            let kids = d.keys.sorted().map { k in
                build(d[k] ?? NSNull(), path: path + [.key(k)], label: k)
            }
            return TreeNode(id: id, path: path, label: label, preview: "辞書 \(d.count)件",
                            isBool: false, isContainer: true, children: kids)
        }
        if let a = v as? [Any] {
            let kids = a.enumerated().map { item in
                build(item.element, path: path + [.index(item.offset)], label: "[\(item.offset)]")
            }
            return TreeNode(id: id, path: path, label: label, preview: "配列 \(a.count)件",
                            isBool: false, isContainer: true, children: kids)
        }
        return TreeNode(id: id, path: path, label: label, preview: TreeOps.scalar(v),
                        isBool: TreeOps.isBool(v), isContainer: false, children: nil)
    }
}

/// plist / JSON のツリー編集（タップで値編集、長押しで追加・削除）
struct TreeEditorView: View {
    let doc: Any
    let commit: (Any) -> Void
    let isInfoPlist: Bool

    static let infoKeys = ["CFBundleDisplayName", "CFBundleIdentifier", "CFBundleShortVersionString",
                           "CFBundleVersion", "MinimumOSVersion", "CFBundleExecutable"]

    @State private var editing: TreeNode?
    @State private var editText = ""
    @State private var showEdit = false
    @State private var adding: TreeNode?
    @State private var showAdd = false
    @State private var newKey = ""
    @State private var newValue = ""
    @State private var deleting: TreeNode?
    @State private var showDelete = false

    private var root: TreeNode { TreeNode.build(doc) }

    var body: some View {
        List {
            if isInfoPlist { infoSection }
            Section("構造（タップで編集・長押しで操作）") {
                OutlineGroup(root.children ?? [], children: \.children) { node in
                    row(node)
                }
            }
        }
        .alert("値を編集", isPresented: $showEdit) {
            TextField("値", text: $editText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("OK") { applyEdit() }
            Button("キャンセル", role: .cancel) {}
        }
        .alert("項目を追加", isPresented: $showAdd) {
            if let n = adding, TreeOps.value(doc, n.path) is [String: Any] {
                TextField("キー名", text: $newKey)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            TextField("値（文字列）", text: $newValue)
            Button("追加") { applyAdd() }
            Button("キャンセル", role: .cancel) {}
        }
        .confirmationDialog("削除しますか？", isPresented: $showDelete, titleVisibility: .visible) {
            Button("削除", role: .destructive) { applyDelete() }
            Button("キャンセル", role: .cancel) {}
        }
    }

    private func row(_ node: TreeNode) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(node.label).font(.body.weight(.medium))
                Text(node.preview).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            Spacer(minLength: 8)
            if node.isBool {
                Toggle("", isOn: boolBinding(node)).labelsHidden()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { startEdit(node) }
        .contextMenu {
            if node.isContainer {
                Button {
                    adding = node
                    newKey = ""
                    newValue = ""
                    showAdd = true
                } label: { Label("項目を追加", systemImage: "plus") }
            }
            Button(role: .destructive) {
                deleting = node
                showDelete = true
            } label: { Label("削除", systemImage: "trash") }
        }
    }

    private func boolBinding(_ node: TreeNode) -> Binding<Bool> {
        Binding(
            get: { (TreeOps.value(doc, node.path) as? Bool) == true },
            set: { commit(TreeOps.set(doc, ArraySlice(node.path), to: $0)) })
    }

    private func startEdit(_ node: TreeNode) {
        guard !node.isContainer, let v = TreeOps.value(doc, node.path), TreeOps.editable(v) else { return }
        editing = node
        editText = TreeOps.scalar(v)
        showEdit = true
    }

    private func applyEdit() {
        guard let n = editing, let old = TreeOps.value(doc, n.path),
              let v = TreeOps.parse(editText, like: old) else { return }
        commit(TreeOps.set(doc, ArraySlice(n.path), to: v))
    }

    private func applyAdd() {
        guard let n = adding, let target = TreeOps.value(doc, n.path) else { return }
        if var d = target as? [String: Any] {
            let k = newKey.trimmingCharacters(in: .whitespaces)
            guard !k.isEmpty else { return }
            d[k] = newValue
            commit(TreeOps.set(doc, ArraySlice(n.path), to: d))
        } else if var a = target as? [Any] {
            a.append(newValue)
            commit(TreeOps.set(doc, ArraySlice(n.path), to: a))
        }
    }

    private func applyDelete() {
        guard let n = deleting, !n.path.isEmpty else { return }
        commit(TreeOps.set(doc, ArraySlice(n.path), to: nil))
    }

    private var infoSection: some View {
        Section("よく使う項目（Info.plist）") {
            ForEach(Self.infoKeys, id: \.self) { key in
                VStack(alignment: .leading, spacing: 4) {
                    Text(key).font(.caption).foregroundStyle(.secondary)
                    TextField(key, text: infoBinding(key))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .disabled(key == "CFBundleExecutable")
                }
            }
        }
    }

    private func infoBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { ((doc as? [String: Any])?[key] as? String) ?? "" },
            set: { commit(TreeOps.set(doc, ArraySlice([PathElem.key(key)]), to: $0)) })
    }
}
