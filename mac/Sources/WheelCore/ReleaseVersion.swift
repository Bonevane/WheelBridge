import Foundation

/// Version numbers as GitHub release tags write them: "v0.2.0", "0.2.10".
public enum ReleaseVersion {
    /// "0.3.10" is newer than "0.3.9". A leading "v" is ignored, and parts
    /// that aren't numbers count as 0.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    /// The tag without its "v".
    public static func clean(_ tag: String) -> String {
        tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
    }

    private static func parts(_ version: String) -> [Int] {
        clean(version).split(whereSeparator: { $0 == "." || $0 == "-" }).map { Int($0) ?? 0 }
    }

    /// The SHA-256 a SHA256SUMS file lists for `fileName`, lowercased, or nil.
    /// Lines look like "<hex>  <name>", as shasum writes them.
    public static func checksum(for fileName: String, in sums: String) -> String? {
        for line in sums.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2 else { continue }
            let name = fields.last.map(String.init)?.trimmingCharacters(in: CharacterSet(charactersIn: "*")) ?? ""
            if name == fileName { return fields[0].lowercased() }
        }
        return nil
    }
}
