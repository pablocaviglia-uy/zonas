import Foundation

// Simulates the three ways a config file gets written and checks which
// DispatchSource setup survives each one.
let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("zonas-watch-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let file = dir.appendingPathComponent("zonas.json5")
try! Data("v0".utf8).write(to: file)

let q = DispatchQueue(label: "watch")
var fileEvents = 0, dirEvents = 0
let lock = NSLock()

var fileSource: DispatchSourceFileSystemObject?
func armFile() {
    fileSource?.cancel()
    let fd = open(file.path, O_EVTONLY)
    guard fd >= 0 else { print("  [!] could not open file"); return }
    let s = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: fd,
        eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke],
        queue: q)
    s.setEventHandler {
        let d = s.data
        lock.lock(); fileEvents += 1; lock.unlock()
        print("  file source fired: \(d)")
        if d.contains(.delete) || d.contains(.rename) || d.contains(.revoke) {
            print("  -> inode gone, re-arming on the path")
            q.asyncAfter(deadline: .now() + 0.05) { armFile() }
        }
    }
    s.setCancelHandler { close(fd) }
    s.resume()
    fileSource = s
}

let dfd = open(dir.path, O_EVTONLY)
let dirSource = DispatchSource.makeFileSystemObjectSource(fileDescriptor: dfd, eventMask: [.write], queue: q)
dirSource.setEventHandler {
    lock.lock(); dirEvents += 1; lock.unlock()
    print("  dir source fired")
}
dirSource.resume()
armFile()
Thread.sleep(forTimeInterval: 0.3)

func phase(_ label: String, _ body: () -> Void) {
    lock.lock(); fileEvents = 0; dirEvents = 0; lock.unlock()
    print("\n== \(label)")
    body()
    Thread.sleep(forTimeInterval: 0.6)
    lock.lock(); print("   RESULT file=\(fileEvents) dir=\(dirEvents) content=\((try? String(contentsOf: file, encoding: .utf8)) ?? "?")"); lock.unlock()
    Thread.sleep(forTimeInterval: 0.3)
}

phase("1. in-place write (echo >>, sed in place)") {
    let h = FileHandle(forWritingAtPath: file.path)!
    h.seekToEndOfFile(); h.write(Data("\n// v1".utf8)); try? h.close()
}

phase("2. atomic replace (vim :w, Data.write .atomic)") {
    try! Data("v2".utf8).write(to: file, options: .atomic)
}

phase("3. mv over it (git checkout, dotfile manager relink)") {
    let stage = dir.appendingPathComponent("stage")
    try! Data("v3".utf8).write(to: stage)
    _ = try! FileManager.default.replaceItemAt(file, withItemAt: stage)
}

phase("4. delete then recreate (some editors)") {
    try! FileManager.default.removeItem(at: file)
    Thread.sleep(forTimeInterval: 0.1)
    try! Data("v4".utf8).write(to: file)
}

dirSource.cancel(); fileSource?.cancel()
print("\ndone")
