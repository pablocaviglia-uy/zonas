import Foundation

func fresh() -> (URL, URL) {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("zonas-sym-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let real = tmp.appendingPathComponent("dotfiles.json5")
    let link = tmp.appendingPathComponent("config.json5")
    try! Data("ORIGINAL".utf8).write(to: real)
    try! FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    return (real, link)
}
func isLink(_ u: URL) -> Bool { (try? FileManager.default.destinationOfSymbolicLink(atPath: u.path)) != nil }
func read(_ u: URL) -> String { (try? String(contentsOf: u, encoding: .utf8)) ?? "<none>" }

// A: plain write through a symlink
var (real, link) = fresh()
try! Data("PLAIN".utf8).write(to: link)
print("[A plain ] link still symlink:", isLink(link), "| real:", read(real))

// B: atomic write through a symlink
(real, link) = fresh()
try! Data("ATOMIC".utf8).write(to: link, options: .atomic)
print("[B atomic] link still symlink:", isLink(link), "| real:", read(real), "| link:", read(link))

// C: atomic write to the RESOLVED path
(real, link) = fresh()
let resolved = link.resolvingSymlinksInPath()
print("[C paths ] link:", link.path)
print("[C paths ] resolved:", resolved.path)
print("[C paths ] real.resolvingSymlinksInPath:", real.resolvingSymlinksInPath().path)
try! Data("ATOMIC-RESOLVED".utf8).write(to: resolved, options: .atomic)
print("[C resolv] link still symlink:", isLink(link), "| real:", read(real))

// D: what URLResourceValues says
(real, link) = fresh()
let vals = try! link.resourceValues(forKeys: [.isSymbolicLinkKey, .canonicalPathKey])
print("[D probe ] isSymbolicLink:", vals.isSymbolicLink ?? false, "| canonicalPath:", vals.canonicalPath ?? "nil")
