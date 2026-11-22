import Foundation

struct RecentItem: Codable, Identifiable {
    var id = UUID()
    let name: String
    let bookmark: Data
    let isDirectory: Bool
    let date: Date

    func resolve() -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    }
}

enum Recents {
    private static let key = "recentItems"

    static func load() -> [RecentItem] {
        guard let d = UserDefaults.standard.data(forKey: key),
              let items = try? JSONDecoder().decode([RecentItem].self, from: d) else { return [] }
        return items
    }

    /// 開いたファイルを最近使った項目に追加(同名は先頭に移動)
    static func add(_ url: URL) {
        guard let bm = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        var items = load().filter { $0.name != url.lastPathComponent }
        items.insert(RecentItem(name: url.lastPathComponent, bookmark: bm, isDirectory: isDir, date: Date()), at: 0)
        if let d = try? JSONEncoder().encode(Array(items.prefix(20))) {
            UserDefaults.standard.set(d, forKey: key)
        }
    }
}
