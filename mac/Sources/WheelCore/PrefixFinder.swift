import Foundation

/// Finds Wine prefixes made by tools other than CrossOver, and the Wine each
/// one runs on. The proxy itself works in any Wine 6 or newer; what differs is
/// where each tool keeps its prefixes and its Wine.
///
/// The tools change their layouts between versions, so nothing here trusts one
/// exact path: it looks in the known places and then searches a little.
public struct PrefixFinder {
    public var home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    /// Every prefix found, apart from CrossOver's, which `Bottle.all` lists.
    public func all() -> [Bottle] {
        var seen = Set<String>()
        return (whisky() + wrappers() + heroic() + plainWine()).filter { seen.insert($0.url.standardizedFileURL.path).inserted }
    }

    // MARK: Whisky

    /// Whisky keeps bottles in its container, and can be told to keep them
    /// anywhere, which it records in BottleVM.plist.
    func whisky() -> [Bottle] {
        let container = home.appendingPathComponent("Library/Containers/com.isaacmarovitz.Whisky")
        var folders = children(of: container.appendingPathComponent("Bottles"))
        let list = container.appendingPathComponent("BottleVM.plist")
        if let plist = NSDictionary(contentsOf: list), let paths = plist["paths"] as? [Any] {
            folders += paths.compactMap { item in
                (item as? String).map { URL(fileURLWithPath: $0) }
                    ?? ((item as? [String: Any])?["relative"] as? String).flatMap { URL(string: $0) }
            }
        }
        let library = Self.findWineLibrary(in: home.appendingPathComponent("Library/Application Support/com.isaacmarovitz.Whisky/Libraries"))
        return folders.filter(Bottle.isPrefix).map { folder in
            Bottle(url: folder, source: .whisky, label: Self.whiskyName(folder), wineLibrary: library)
        }
    }

    private static func whiskyName(_ folder: URL) -> String? {
        guard let metadata = NSDictionary(contentsOf: folder.appendingPathComponent("Metadata.plist")) else { return nil }
        if let info = metadata["info"] as? [String: Any], let name = info["name"] as? String { return name }
        return metadata["name"] as? String
    }

    // MARK: Wrappers

    /// Sikarugir, Kegworks and Wineskin each make one app per game, with the
    /// prefix and its own Wine inside the bundle.
    func wrappers() -> [Bottle] {
        let folders = ["Sikarugir", "Kegworks", "Wineskin"].flatMap { name in
            [home.appendingPathComponent("Applications/\(name)"), URL(fileURLWithPath: "/Applications/\(name)")]
        }
        return folders.flatMap(children).filter { $0.pathExtension == "app" }.compactMap { app in
            let contents = app.appendingPathComponent("Contents")
            guard let prefix = Self.findPrefix(in: contents, depth: 3) else { return nil }
            let library = Self.findWineLibrary(in: contents.appendingPathComponent("SharedSupport"))
                ?? Self.findWineLibrary(in: contents)
            return Bottle(url: prefix, source: .wrapper, label: app.deletingPathExtension().lastPathComponent, wineLibrary: library)
        }
    }

    // MARK: Heroic

    /// Heroic writes one settings file per game, naming its prefix and its Wine.
    /// Games set to run in a CrossOver bottle are left to the CrossOver list.
    func heroic() -> [Bottle] {
        let support = home.appendingPathComponent("Library/Application Support/heroic")
        var result: [Bottle] = []
        for file in children(of: support.appendingPathComponent("GamesConfig")) where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            for case let settings as [String: Any] in root.values {
                guard !result.contains(where: { $0.url.path == (settings["winePrefix"] as? String) }),
                      let path = settings["winePrefix"] as? String, !path.isEmpty else { continue }
                let wine = settings["wineVersion"] as? [String: Any]
                if (wine?["type"] as? String)?.lowercased() == "crossover" { continue }
                let prefix = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                guard Bottle.isPrefix(prefix) else { continue }
                let library = (wine?["bin"] as? String).flatMap { Self.wineLibrary(nearBinary: URL(fileURLWithPath: $0)) }
                    ?? Self.findWineLibrary(in: support.appendingPathComponent("tools"))
                result.append(Bottle(url: prefix, source: .heroic, wineLibrary: library))
            }
        }
        let fallback = Self.findWineLibrary(in: support.appendingPathComponent("tools"))
        for prefix in children(of: home.appendingPathComponent("Games/Heroic/Prefixes/default")) where Bottle.isPrefix(prefix) {
            if !result.contains(where: { $0.url.standardizedFileURL == prefix.standardizedFileURL }) {
                result.append(Bottle(url: prefix, source: .heroic, wineLibrary: fallback))
            }
        }
        return result
    }

    // MARK: Plain Wine

    /// ~/.wine, run with any Wine on the Mac: the Wine apps, Homebrew, or
    /// Apple's Game Porting Toolkit.
    func plainWine() -> [Bottle] {
        let prefix = home.appendingPathComponent(".wine")
        guard Bottle.isPrefix(prefix) else { return [] }
        return [Bottle(url: prefix, source: .wine, wineLibrary: Self.knownWineLibraries(home: home).first)]
    }

    /// Wine installs outside any launcher, best first.
    public static func knownWineLibraries(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let places = [
            "/Applications/Wine Stable.app", "/Applications/Wine Staging.app", "/Applications/Wine Devel.app",
            home.appendingPathComponent("Applications/Wine Stable.app").path,
            "/opt/homebrew/opt/game-porting-toolkit", "/usr/local/opt/game-porting-toolkit",
            "/opt/homebrew/lib/wine", "/usr/local/lib/wine",
        ]
        return places.compactMap { findWineLibrary(in: URL(fileURLWithPath: $0)) }
    }

    // MARK: Searching

    /// A ".../lib/wine" folder whose x86_64-windows/dinput8.dll is a real Wine
    /// builtin, searched for a few levels down.
    public static func findWineLibrary(in root: URL, depth: Int = 7) -> URL? {
        let fm = FileManager.default
        guard depth >= 0, fm.fileExists(atPath: root.path) else { return nil }
        if BottleInstaller.isWineBuiltin(root.appendingPathComponent("x86_64-windows/dinput8.dll")) { return root }
        guard depth > 0 else { return nil }
        let items = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []
        // Prefixes hold thousands of files and never a Wine, so skip them.
        for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && !isPrefix(item) {
            if let found = findWineLibrary(in: item, depth: depth - 1) { return found }
        }
        return nil
    }

    /// The library that goes with a wine binary such as ".../bin/wine64".
    static func wineLibrary(nearBinary binary: URL) -> URL? {
        var folder = binary.deletingLastPathComponent()
        for _ in 0..<4 {
            if let found = findWineLibrary(in: folder.appendingPathComponent("lib/wine"), depth: 0) { return found }
            folder.deleteLastPathComponent()
        }
        return nil
    }

    static func findPrefix(in root: URL, depth: Int) -> URL? {
        if Bottle.isPrefix(root) { return root }
        guard depth > 0 else { return nil }
        let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for item in items where (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            if let found = findPrefix(in: item, depth: depth - 1) { return found }
        }
        return nil
    }

    private static func isPrefix(_ url: URL) -> Bool { Bottle.isPrefix(url) }

    private func children(of folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
