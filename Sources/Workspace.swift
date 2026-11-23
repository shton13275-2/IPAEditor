import Foundation
import CryptoKit
import ZIPFoundation

enum WorkspaceKind { case archive, folder, file }
enum PickerMode { case file, folder }

enum FileChange: Identifiable, Hashable {
    case modified(String), added(String), removed(String)

    var path: String {
        switch self {
        case .modified(let p), .added(let p), .removed(let p): return p
        }
    }
    var id: String { "\(label):\(path)" }
    var label: String {
        switch self {
        case .modified: return "変更"
        case .added: return "追加"
        case .removed: return "削除"
        }
    }
}

struct LeaveRequest: Identifiable {
    enum Kind { case unsavedEditor, unexportedArchive }
    let id = UUID()
    let kind: Kind
    let action: () -> Void
}

struct SearchHit: Identifiable {
    let id = UUID()
    let url: URL
    let relative: String
    let reason: String
}

final class Workspace: ObservableObject {
    @Published var root: URL?
    @Published private(set) var kind: WorkspaceKind = .folder
    @Published private(set) var title = ""
    @Published private(set) var archiveExt = "ipa"
    @Published private(set) var session = UUID()
    @Published var busy = false
    @Published var progress: Double?
    @Published var error: String?
    @Published var pickerMode: PickerMode?
    @Published var shareURL: URL?
    @Published var recents: [RecentItem] = Recents.load()
    @Published var editorDirty = false
    @Published var pendingLeave: LeaveRequest?

    /// 編集画面が登録する保存処理(成功したら true)
    var editorSave: (() -> Bool)?

    private let fm = FileManager.default
    private var accessed: URL?
    private var tempDir: URL?
    private var originalCopy: URL?
    private var baseline: [String: String] = [:]
    private var currentProgress: Progress?
    private var progressTimer: Timer?

    // MARK: 開く・閉じる

    func open(_ url: URL) {
        close()
        if url.startAccessingSecurityScopedResource() { accessed = url }
        Recents.add(url)
        recents = Recents.load()
        let ext = url.pathExtension.lowercased()
        if isDir(url) {
            present(url, .folder, url.lastPathComponent)
        } else if ext == "ipa" || ext == "zip" {
            openArchive(url, ext: ext)
        } else {
            present(url, .file, url.lastPathComponent)
        }
    }

    func openRecent(_ item: RecentItem) {
        guard let url = item.resolve() else {
            error = "この項目は開けません（移動・削除された可能性があります）"
            return
        }
        requestLeave { self.open(url) }
    }

    func close() {
        root = nil
        session = UUID()
        editorDirty = false
        editorSave = nil
        accessed?.stopAccessingSecurityScopedResource()
        accessed = nil
        for u in [tempDir, originalCopy].compactMap({ $0 }) { try? fm.removeItem(at: u) }
        tempDir = nil
        originalCopy = nil
        baseline = [:]
    }

    /// 未保存の変更があれば確認を出してから action を実行する
    func requestLeave(_ action: @escaping () -> Void) {
        if editorDirty {
            pendingLeave = LeaveRequest(kind: .unsavedEditor, action: action)
            return
        }
        guard kind == .archive, root != nil else { action(); return }
        computeChanges { [weak self] changes in
            guard let self else { return }
            if changes.isEmpty {
                action()
            } else {
                self.pendingLeave = LeaveRequest(kind: .unexportedArchive, action: action)
            }
        }
    }

    private func present(_ url: URL, _ kind: WorkspaceKind, _ title: String) {
        self.kind = kind
        self.title = title
        self.root = url
        self.session = UUID()
    }

    // MARK: 展開・書き出し（進捗・キャンセル付き）

    private func openArchive(_ url: URL, ext: String) {
        let fm = self.fm
        let dir = fm.temporaryDirectory.appendingPathComponent("ws-" + UUID().uuidString)
        let orig = fm.temporaryDirectory.appendingPathComponent("orig-" + UUID().uuidString + "." + ext)
        let prog = Progress(totalUnitCount: 1)
        currentProgress = prog
        startProgressTimer()
        busy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<[String: String], Error> = Result {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try fm.copyItem(at: url, to: orig)
                try fm.unzipItem(at: orig, to: dir, progress: prog)
                return try Workspace.hashTree(at: dir)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.stopProgressTimer()
                self.busy = false
                self.currentProgress = nil
                switch result {
                case .success(let base):
                    self.tempDir = dir
                    self.originalCopy = orig
                    self.baseline = base
                    self.archiveExt = ext
                    self.present(dir, .archive, url.deletingPathExtension().lastPathComponent)
                case .failure(let e):
                    try? fm.removeItem(at: dir)
                    try? fm.removeItem(at: orig)
                    self.accessed?.stopAccessingSecurityScopedResource()
                    self.accessed = nil
                    self.error = prog.isCancelled ? "展開をキャンセルしました" : "展開に失敗しました: \(e.localizedDescription)"
                }
            }
        }
    }

    func cancelBusy() { currentProgress?.cancel() }

    private func startProgressTimer() {
        progress = 0
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let p = self.currentProgress else { return }
            self.progress = p.fractionCompleted
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
        progress = nil
    }

    /// 展開フォルダを ipa / zip に再圧縮（署名削除オプション付き）
    func exportArchive(stripSignature: Bool, completion: @escaping (URL?) -> Void) {
        guard kind == .archive, let dir = tempDir else { completion(nil); return }
        let fm = self.fm
        let name = title
        let ext = archiveExt
        busy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let stage = fm.temporaryDirectory.appendingPathComponent("stage-" + UUID().uuidString)
            let out = fm.temporaryDirectory.appendingPathComponent("\(name)-modified.\(ext)")
            let result: Result<URL, Error> = Result {
                try fm.copyItem(at: dir, to: stage)
                defer { try? fm.removeItem(at: stage) }
                if stripSignature { Workspace.stripSignature(in: stage) }
                try? fm.removeItem(at: out)
                try fm.zipItem(at: stage, to: out, shouldKeepParent: false)
                return out
            }
            DispatchQueue.main.async {
                self?.busy = false
                switch result {
                case .success(let u): completion(u)
                case .failure(let e):
                    self?.error = "書き出しに失敗: \(e.localizedDescription)"
                    completion(nil)
                }
            }
        }
    }

    // MARK: 差分（展開時の状態との比較）

    func computeChanges(_ completion: @escaping ([FileChange]) -> Void) {
        guard kind == .archive, let dir = tempDir else { completion([]); return }
        let base = baseline
        DispatchQueue.global(qos: .userInitiated).async {
            let now = (try? Workspace.hashTree(at: dir)) ?? [:]
            var out: [FileChange] = []
            for (p, h) in now {
                if let old = base[p] {
                    if old != h { out.append(.modified(p)) }
                } else {
                    out.append(.added(p))
                }
            }
            for p in base.keys where now[p] == nil { out.append(.removed(p)) }
            out.sort { $0.path < $1.path }
            DispatchQueue.main.async { completion(out) }
        }
    }

    /// 1件を元の状態に戻す
    func restore(_ change: FileChange) {
        guard let dir = tempDir else { return }
        let target = dir.appendingPathComponent(change.path)
        do {
            switch change {
            case .added:
                try fm.removeItem(at: target)
            case .modified, .removed:
                guard let orig = originalCopy else { return }
                let archive = try Archive(url: orig, accessMode: .read)
                guard let entry = archive[change.path] else { throw CocoaError(.fileNoSuchFile) }
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: target)
                try archive.extract(entry, to: target)
            }
        } catch {
            self.error = "元に戻せませんでした: \(error.localizedDescription)"
        }
    }

    // MARK: ファイル操作

    func list(_ dir: URL) -> [URL] {
        let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return items.sorted { a, b in
            let da = isDir(a), db = isDir(b)
            if da != db { return da }
            return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
        }
    }

    func allFolders(under root: URL) -> [URL] {
        var out = [root]
        if let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let u as URL in en where isDir(u) { out.append(u) }
        }
        return out
    }

    func isDir(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    func delete(_ url: URL) {
        do { try fm.removeItem(at: url) } catch { self.error = "削除に失敗: \(error.localizedDescription)" }
    }

    func rename(_ url: URL, to name: String) {
        let dest = url.deletingLastPathComponent().appendingPathComponent(name)
        do { try fm.moveItem(at: url, to: dest) } catch { self.error = "名前変更に失敗: \(error.localizedDescription)" }
    }

    func makeFolder(in dir: URL, name: String) {
        do { try fm.createDirectory(at: dir.appendingPathComponent(name), withIntermediateDirectories: false) }
        catch { self.error = "フォルダを作成できません: \(error.localizedDescription)" }
    }

    func makeFile(in dir: URL, name: String) {
        let u = dir.appendingPathComponent(name)
        if fm.fileExists(atPath: u.path) || !fm.createFile(atPath: u.path, contents: Data()) {
            self.error = "ファイルを作成できません（同名の項目がある可能性があります）"
        }
    }

    func importFile(_ src: URL, into dir: URL) {
        copyExternal(src, to: dir.appendingPathComponent(src.lastPathComponent))
    }

    func replace(_ target: URL, with src: URL) {
        copyExternal(src, to: target)
    }

    func copyItem(_ src: URL, to dest: URL) {
        do { try fm.copyItem(at: src, to: dest) } catch { self.error = "複製に失敗: \(error.localizedDescription)" }
    }

    /// 同じワークスペース内での移動・コピー
    func transfer(_ urls: [URL], to dir: URL, move: Bool) {
        let destPath = dir.standardizedFileURL.path
        for u in urls {
            let src = u.standardizedFileURL.path
            if destPath == src || destPath.hasPrefix(src + "/") {
                error = "フォルダを自分自身の中へは移動・コピーできません"
                continue
            }
            let dest = dir.appendingPathComponent(u.lastPathComponent)
            if dest.standardizedFileURL.path == src { continue }
            if fm.fileExists(atPath: dest.path) {
                error = "同名の項目があるため中止しました: \(u.lastPathComponent)"
                continue
            }
            do {
                if move { try fm.moveItem(at: u, to: dest) } else { try fm.copyItem(at: u, to: dest) }
            } catch {
                self.error = "移動・コピーに失敗: \(error.localizedDescription)"
            }
        }
    }

    private func copyExternal(_ src: URL, to dest: URL) {
        let access = src.startAccessingSecurityScopedResource()
        defer { if access { src.stopAccessingSecurityScopedResource() } }
        do {
            try? fm.removeItem(at: dest)
            try fm.copyItem(at: src, to: dest)
        } catch {
            self.error = "コピーに失敗: \(error.localizedDescription)"
        }
    }

    /// 再帰検索（名前、必要なら小さなテキストの中身）
    func search(_ query: String, in dir: URL, contents: Bool, completion: @escaping ([SearchHit]) -> Void) {
        let base = dir.standardizedFileURL.path + "/"
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var hits: [SearchHit] = []
            if let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]) {
                for case let u as URL in en {
                    if hits.count >= 300 { break }
                    let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    let rel = String(u.standardizedFileURL.path.dropFirst(base.count))
                    if u.lastPathComponent.localizedCaseInsensitiveContains(query) {
                        hits.append(SearchHit(url: u, relative: rel, reason: isDir ? "フォルダ名" : "ファイル名"))
                        continue
                    }
                    if contents, !isDir,
                       let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize), size < 1_000_000,
                       let d = try? Data(contentsOf: u), !d.prefix(8000).contains(0),
                       let s = String(data: d, encoding: .utf8), s.localizedCaseInsensitiveContains(query) {
                        hits.append(SearchHit(url: u, relative: rel, reason: "内容"))
                    }
                }
            }
            DispatchQueue.main.async { completion(hits) }
        }
    }

    // MARK: 表示用

    func icon(_ url: URL) -> String {
        if isDir(url) { return "folder.fill" }
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "bmp", "tiff", "tif", "ico": return "photo"
        case "plist": return "list.bullet.rectangle"
        case "json", "xml", "txt", "md", "strings", "yml", "yaml", "csv", "log", "js", "html", "css", "swift": return "doc.text"
        case "db", "sqlite", "sqlite3": return "cylinder"
        case "obj", "usdz", "usd", "usda", "usdc", "dae", "stl", "ply", "scn", "abc", "gltf", "glb": return "cube"
        default: return "doc"
        }
    }

    func sizeText(_ url: URL) -> String {
        let n = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }

    // MARK: ハッシュ・署名削除

    static func hashTree(at root: URL) throws -> [String: String] {
        var out: [String: String] = [:]
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return out }
        let prefix = root.standardizedFileURL.path + "/"
        for case let u as URL in en {
            if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
            let rel = String(u.standardizedFileURL.path.dropFirst(prefix.count))
            out[rel] = try sha256(u)
        }
        return out
    }

    static func sha256(_ url: URL) throws -> String {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        var h = SHA256()
        while let d = try fh.read(upToCount: 1 << 20), !d.isEmpty { h.update(data: d) }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func stripSignature(in root: URL) {
        let fm = FileManager.default
        let payload = root.appendingPathComponent("Payload")
        guard let apps = try? fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil) else { return }
        for app in apps where app.pathExtension == "app" {
            try? fm.removeItem(at: app.appendingPathComponent("_CodeSignature"))
            try? fm.removeItem(at: app.appendingPathComponent("embedded.mobileprovision"))
        }
    }
}
