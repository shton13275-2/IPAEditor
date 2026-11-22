import Foundation
import ZIPFoundation

final class IPAManager: ObservableObject {
    @Published var workDir: URL?
    @Published var ipaName = "app"
    @Published var message = ""

    private let fm = FileManager.default

    /// ipaを作業フォルダへ展開
    func open(ipa url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.unzipItem(at: url, to: dir)
            ipaName = url.deletingPathExtension().lastPathComponent
            workDir = dir
            message = "展開しました"
        } catch {
            message = "展開失敗: \(error.localizedDescription)"
        }
    }

    /// 作業フォルダをipaに再圧縮
    func export() -> URL? {
        guard let dir = workDir else { return nil }
        let out = fm.temporaryDirectory.appendingPathComponent("\(ipaName)-modified.ipa")
        try? fm.removeItem(at: out)
        do {
            try fm.zipItem(at: dir, to: out, shouldKeepParent: false)
            return out
        } catch {
            message = "書き出し失敗: \(error.localizedDescription)"
            return nil
        }
    }

    func list(_ dir: URL) -> [URL] {
        let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return items.sorted { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }
    }

    func isDir(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    func delete(_ url: URL) { try? fm.removeItem(at: url) }

    /// ファイルの差し替え(外部ファイルを同名で上書き)
    func replace(_ target: URL, with source: URL) {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        try? fm.removeItem(at: target)
        try? fm.copyItem(at: source, to: target)
    }
}
