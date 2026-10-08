import Foundation

enum RemotePath {
    static func normalize(_ path: String, root: String) throws -> String {
        guard path.hasPrefix("/"), root.hasPrefix("/"), !path.contains("\0"), !root.contains("\0") else { throw BridgeError.invalidPath }
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { throw BridgeError.invalidPath }
            parts.append(part)
        }
        let result = "/" + parts.joined(separator: "/")
        let base = root == "/" ? "/" : root.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let canonicalRoot = base == "/" ? "/" : "/" + base
        guard canonicalRoot != "/", result == canonicalRoot || result.hasPrefix(canonicalRoot + "/") else { throw BridgeError.invalidPath }
        return result
    }
    static func child(_ name: String, of parent: String, root: String) throws -> String {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { throw BridgeError.invalidPath }
        return try normalize(parent + "/" + name, root: root)
    }
    static func parent(_ path: String, root: String) -> String {
        if path == root { return root }
        return (try? normalize((path as NSString).deletingLastPathComponent, root: root)) ?? root
    }
    // Only the remote POSIX shell receives this representation. The host never uses a shell.
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func folded(_ value: String) -> String { value.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
    static func availableName(_ name: String, existing: [String]) -> String {
        let taken = Set(existing.map(folded))
        if !taken.contains(folded(name)) { return name }
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            if !taken.contains(folded(candidate)) { return candidate }
            n += 1
        }
    }
}
