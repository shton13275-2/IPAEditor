import SwiftUI
import CryptoKit

struct DigestRow: Identifiable {
    let id = UUID()
    let name: String
    let value: String
}

enum Analyzer {
    /// MD5 / SHA-1 / SHA-256 を1回の読み込みで計算
    static func digests(_ url: URL) throws -> [DigestRow] {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        var md5 = Insecure.MD5()
        var sha1 = Insecure.SHA1()
        var sha256 = SHA256()
        while let chunk = try fh.read(upToCount: 1 << 20), !chunk.isEmpty {
            md5.update(data: chunk)
            sha1.update(data: chunk)
            sha256.update(data: chunk)
        }
        return [
            DigestRow(name: "MD5", value: hexString(md5.finalize())),
            DigestRow(name: "SHA-1", value: hexString(sha1.finalize())),
            DigestRow(name: "SHA-256", value: hexString(sha256.finalize())),
        ]
    }

    static func hexString<S: Sequence>(_ s: S) -> String where S.Element == UInt8 {
        s.map { String(format: "%02x", $0) }.joined()
    }

    /// 印字可能な文字の連続（4文字以上）を抽出
    static func strings(in data: Data, minLength: Int = 4, limit: Int = 5000) -> [String] {
        var out: [String] = []
        var cur: [UInt8] = []
        for b in data {
            if (b >= 0x20 && b < 0x7F) || b == 0x09 {
                cur.append(b)
            } else {
                if cur.count >= minLength {
                    out.append(String(decoding: cur, as: UTF8.self))
                    if out.count >= limit { break }
                }
                cur.removeAll(keepingCapacity: true)
            }
        }
        return out
    }
}

/// Mach-O（実行ファイル）の基本情報
enum MachOInfo {
    static func u32(_ d: Data, _ o: Int, big: Bool = false) -> UInt32? {
        guard o >= 0, o + 4 <= d.count else { return nil }
        var v: UInt32 = 0
        for i in 0..<4 {
            let byte = UInt32(d[d.startIndex + o + (big ? i : 3 - i)])
            v = (v << 8) | byte
        }
        return v
    }

    static func describe(_ d: Data) -> [String]? {
        guard let le = u32(d, 0) else { return nil }
        let be = u32(d, 0, big: true) ?? 0
        if be == 0xCAFEBABE {
            let n = Int(u32(d, 4, big: true) ?? 0)
            var out = ["ユニバーサル（Fat）: \(n)アーキテクチャ"]
            for i in 0..<min(n, 8) {
                let o = 8 + i * 20
                guard let cpu = u32(d, o, big: true), let off = u32(d, o + 8, big: true) else { break }
                out.append("—— \(cpuName(cpu)) (オフセット 0x\(String(off, radix: 16)))")
                out += thin(d, base: Int(off), is64: cpu & 0x0100_0000 != 0)
            }
            return out
        }
        if le == 0xFEEDFACF { return thin(d, base: 0, is64: true) }
        if le == 0xFEEDFACE { return thin(d, base: 0, is64: false) }
        return nil
    }

    private static func thin(_ d: Data, base: Int, is64: Bool) -> [String] {
        guard let cpu = u32(d, base + 4), let ft = u32(d, base + 12), let ncmds = u32(d, base + 16) else {
            return ["ヘッダーを読めません"]
        }
        var out = ["CPU: \(cpuName(cpu))", "種類: \(fileType(ft))"]
        var off = base + (is64 ? 32 : 28)
        var dylibs: [String] = []
        for _ in 0..<min(Int(ncmds), 2000) {
            guard let cmd = u32(d, off), let size = u32(d, off + 4), size >= 8 else { break }
            switch cmd {
            case 0x32:
                if let p = u32(d, off + 8), let minos = u32(d, off + 12) {
                    out.append("プラットフォーム: \(platform(p)) / 最低 \(version(minos))")
                }
            case 0x25:
                if let v = u32(d, off + 8) { out.append("最低iOS: \(version(v))") }
            case 0x21, 0x2C:
                if let c = u32(d, off + 16) { out.append("暗号化: \(c == 0 ? "なし" : "あり")") }
            case 0xC, 0x8000_0018:
                if let no = u32(d, off + 8) {
                    dylibs.append(cString(d, off + Int(no), end: off + Int(size)))
                }
            default:
                break
            }
            off += Int(size)
        }
        if !dylibs.isEmpty {
            out.append("依存ライブラリ（\(dylibs.count)件）")
            out += dylibs.prefix(40).map { "  " + $0 }
        }
        return out
    }

    private static func cString(_ d: Data, _ start: Int, end: Int) -> String {
        var bytes: [UInt8] = []
        var i = start
        let stop = min(end, d.count)
        while i < stop, d[d.startIndex + i] != 0 {
            bytes.append(d[d.startIndex + i])
            i += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func version(_ v: UInt32) -> String {
        "\(v >> 16).\((v >> 8) & 0xFF).\(v & 0xFF)"
    }

    private static func cpuName(_ c: UInt32) -> String {
        switch c {
        case 0x0100_000C: return "arm64"
        case 0x0000_000C: return "arm"
        case 0x0100_0007: return "x86_64"
        case 0x0000_0007: return "i386"
        default: return String(format: "0x%08X", c)
        }
    }

    private static func fileType(_ t: UInt32) -> String {
        switch t {
        case 1: return "Object"
        case 2: return "Executable"
        case 6: return "Dylib"
        case 8: return "Bundle"
        default: return "その他(\(t))"
        }
    }

    private static func platform(_ p: UInt32) -> String {
        switch p {
        case 1: return "macOS"
        case 2: return "iOS"
        case 3: return "tvOS"
        case 4: return "watchOS"
        case 6: return "Mac Catalyst"
        case 7: return "iOS Simulator"
        default: return "その他(\(p))"
        }
    }
}

/// ハッシュ・Mach-O・文字列の解析画面
struct AnalysisView: View {
    let url: URL
    let data: Data
    @State private var digests: [DigestRow] = []
    @State private var macho: [String]?
    @State private var strings: [String] = []
    @State private var query = ""

    private var shownStrings: [String] {
        let list = query.isEmpty ? strings : strings.filter { $0.localizedCaseInsensitiveContains(query) }
        return Array(list.prefix(500))
    }

    var body: some View {
        List {
            Section("ファイル") {
                LabeledContent("名前", value: url.lastPathComponent)
                LabeledContent("サイズ", value: "\(data.count) バイト")
            }
            Section("ハッシュ") {
                if digests.isEmpty { ProgressView() }
                ForEach(digests) { r in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.name).font(.caption.bold())
                        Text(r.value).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
            if let m = macho {
                Section("Mach-O") {
                    ForEach(m.indices, id: \.self) { i in
                        Text(m[i]).font(.footnote)
                    }
                }
            }
            Section("文字列（\(strings.count)件・表示は最大500件）") {
                ForEach(shownStrings, id: \.self) { s in
                    Text(s).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
        }
        .searchable(text: $query, prompt: "文字列を検索")
        .task { await load() }
    }

    private func load() async {
        let u = url
        let d = data
        digests = await Task.detached(priority: .userInitiated) { (try? Analyzer.digests(u)) ?? [] }.value
        macho = await Task.detached { MachOInfo.describe(d) }.value
        strings = await Task.detached { Analyzer.strings(in: d) }.value
    }
}
