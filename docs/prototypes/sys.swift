import AppKit
import Foundation

// ---- 1. Fraction exactness at the right edge
let third = 1.0/3.0, twoThirds = 2.0/3.0
print("[frac] 2/3 + 1/3 == 1.0 :", twoThirds + third == 1.0, "->", twoThirds + third)
print("[frac] 0.3333 x3       :", 0.3333*3)

// ---- 2. Screen identity APIs
for s in NSScreen.screens {
    let num = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    let did = CGDirectDisplayID(num?.uint32Value ?? 0)
    let uuid = CGDisplayCreateUUIDFromDisplayID(did)?.takeRetainedValue()
    print("[screen] name=\(s.localizedName) visibleFrame=\(s.visibleFrame) builtin=\(CGDisplayIsBuiltin(did) != 0) uuid=\(uuid.map { CFUUIDCreateString(nil, $0) as String } ?? "nil")")
}

// ---- 3. Symlink + atomic write
let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("zonas-symlink-test-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
let real = tmp.appendingPathComponent("real.json5")
let link = tmp.appendingPathComponent("link.json5")
try! Data("ORIGINAL".utf8).write(to: real)
try! FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
try! Data("ATOMIC-WRITE".utf8).write(to: link, options: .atomic)
let stillLink = (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil
print("[symlink] after .atomic write, link is still a symlink:", stillLink)
print("[symlink] real file content:", String(data: try! Data(contentsOf: real), encoding: .utf8)!)
print("[symlink] resolvingSymlinksInPath works:", link.resolvingSymlinksInPath().path == real.resolvingSymlinksInPath().path)

// non-atomic, for contrast
try! Data("ORIGINAL2".utf8).write(to: real)
try! Data("PLAIN-WRITE".utf8).write(to: link)
print("[symlink] after plain write, real content:", String(data: try! Data(contentsOf: real), encoding: .utf8)!)

// ---- 4. Number-or-string decoding (the "1/3" ratio)
enum Frac: Codable, Equatable {
    case number(Double), ratio(Int, Int)
    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        let s = try c.decode(String.self)
        let parts = s.split(separator: "/")
        guard parts.count == 2, let n = Int(parts[0]), let m = Int(parts[1]), m != 0 else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a ratio: \(s)")
        }
        self = .ratio(n, m)
    }
    func encode(to e: Encoder) throws {
        var c = e.singleValueContainer()
        switch self { case .number(let n): try c.encode(n); case .ratio(let n, let m): try c.encode("\(n)/\(m)") }
    }
    var value: Double { switch self { case .number(let n): return n; case .ratio(let n, let m): return Double(n)/Double(m) } }
}
struct Z: Codable { var name: String; var x: Frac; var width: Frac }
let d = JSONDecoder(); d.allowsJSON5 = true
let zs = try! d.decode([Z].self, from: Data(#"[{name:"a",x:"2/3",width:"1/3"},{name:"b",x:0.5,width:.25}]"#.utf8))
print("[ratio] decoded:", zs.map { "\($0.name) x=\($0.x.value) w=\($0.width.value)" })
print("[ratio] 2/3 + 1/3 via Frac == 1.0:", zs[0].x.value + zs[0].width.value == 1.0)
