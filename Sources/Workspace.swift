import Foundation
import ZIPFoundation

enum WorkspaceKind { case archive, folder, file }
enum PickerMode { case file, folder }

/// 開いているもの(ipa/zip展開結果・フォルダ・単体ファイル)を管理する
final class Workspace: ObservableObject {
    @Published var root: URL?
    @Published private(set) var kind: WorkspaceKind = .folder
    @Published private(set) var title = ""
    @Published private(set) var archiveExt = "ipa"
    @Published private(set) var session = UUID()
    @Published var busy = false
    @Published var error: String?
    @Published var pickerMode: PickerMode?
    @Published var shareURL: URL?

    private let fm = FileManager.default
    private var accessed: URL?
    private var tempDir: URL?

    // MARK: 開く・閉じる

    func open(_ url: URL) {
        close()
        if url.startAccessingSecurityScopedResource() { accessed = url }
        let ext = url.pathExtension.lowercased()
        if isDir(url) {
            present(url, kind: .folder, title: url.lastPathComponent)
        } else if ext == "ipa" || ext == "zip" {
            openArchive(url, ext: ext)
        } else {
            present(url, kind: .file, title: url.lastPathComponent)
        }
    }

    func close() {
        root = nil
        session = UUID()
        releaseAccess()
        if let t = tempDir { try? fm.removeItem(at: t); tempDir = nil }
    }

    private func present(_ url: URL, kind: WorkspaceKind, title: String) {
        session = UUID()
        self.kind = kind
        self.title = title
        root = url
    }

    private func releaseAccess() {
        accessed?.stopAccessingSecurityScopedResource()
        accessed = nil
    }

    private func openArchive(_ url: URL, ext: String) {
        busy = true
        let fm = self.fm
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<Void, Error> = Result {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try fm.unzipItem(at: url, to: dir)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                self.releaseAccess()
                switch result {
                case .success:
                    self.tempDir = dir
                    self.archiveExt = ext
                    self.present(dir, kind: .archive, title: url.deletingPathExtension().lastPathComponent)
                case .failure(let e):
                    try? fm.removeItem(at: dir)
                    self.error = "展開に失敗しました: \(e.localizedDescription)"
                }
            }
        }
    }

    /// 展開したフォルダをipa/zipに再圧縮
    func exportArchive(completion: @escaping (URL?) -> Void) {
        guard kind == .archive, let dir = root else { completion(nil); return }
        busy = true
        let fm = self.fm
        let out = fm.temporaryDirectory.appendingPathComponent("\(title)-modified.\(archiveExt)")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            try? fm.removeItem(at: out)
            let result: Result<Void, Error> = Result {
                try fm.zipItem(at: dir, to: out, shouldKeepParent: false)
            }
            DispatchQueue.main.async {
                self?.busy = false
                switch result {
                case .success: completion(out)
                case .failure(let e):
                    self?.error = "書き出しに失敗しました: \(e.localizedDescription)"
                    completion(nil)
                }
            }
        }
    }

    // MARK: ファイル操作

    func list(_ dir: URL) -> [URL] {
        let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey])) ?? []
        return items.sorted { a, b in
            let da = isDir(a), db = isDir(b)
            if da != db { return da }
            return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
        }
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
        do {
            try fm.createDirectory(at: dir.appendingPathComponent(name), withIntermediateDirectories: false)
        } catch { self.error = "フォルダ作成に失敗: \(error.localizedDescription)" }
    }

    func makeFile(in dir: URL, name: String) {
        let u = dir.appendingPathComponent(name)
        if fm.fileExists(atPath: u.path) || !fm.createFile(atPath: u.path, contents: Data()) {
            self.error = "ファイルを作成できませんでした(同名のファイルがある可能性があります)"
        }
    }

    /// 外部ファイルをフォルダへ追加(同名は上書き)
    func importFile(_ src: URL, into dir: URL) {
        copy(src, to: dir.appendingPathComponent(src.lastPathComponent))
    }

    /// 既存ファイルを外部ファイルで差し替え(ファイル名は維持)
    func replace(_ target: URL, with src: URL) {
        copy(src, to: target)
    }

    private func copy(_ src: URL, to dest: URL) {
        let access = src.startAccessingSecurityScopedResource()
        defer { if access { src.stopAccessingSecurityScopedResource() } }
        try? fm.removeItem(at: dest)
        do { try fm.copyItem(at: src, to: dest) } catch { self.error = "コピーに失敗: \(error.localizedDescription)" }
    }

    // MARK: 表示用

    func icon(_ url: URL) -> String {
        if isDir(url) { return "folder.fill" }
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "bmp", "tiff", "tif", "ico": return "photo"
        case "plist": return "list.bullet.rectangle"
        case "txt", "json", "xml", "md", "strings", "yml", "yaml", "csv", "log", "js", "html", "css",
             "swift", "c", "h", "cfg", "ini", "conf": return "doc.text"
        default: return "doc"
        }
    }

    func sizeText(_ url: URL) -> String {
        let n = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }
}
