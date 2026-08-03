import Foundation

struct Zone: Codable { var name: String; var x: Double; var y: Double; var width: Double; var height: Double }
struct Layout: Codable { var name: String; var zones: [Zone] }
struct Config: Codable { var version: Int; var layouts: [Layout] }

let src = """
{
  // a comment
  version: 1,
  /* block */
  layouts: [
    { name: 'Three Columns', zones: [
        { name: "Left", x: 0, y: 0, width: .25, height: 1 },   // trailing comment
        { name: "Center", x: 0.25, y: 0, width: 0.5, height: 1 },
    ]},
  ],
}
"""
let dec = JSONDecoder()
dec.allowsJSON5 = true
do {
  let c = try dec.decode(Config.self, from: Data(src.utf8))
  print("OK decode: version=", c.version, "layouts=", c.layouts.count, "zones=", c.layouts[0].zones.count, "firstW=", c.layouts[0].zones[0].width)
} catch { print("FAIL decode:", error) }

let bad = "{ version: 1, layouts: [ { name: 'x', zones: [ { name: 'a', x: 0, y: 0, width: 0.5, heigth: 1 } ] } ] }"
do { _ = try dec.decode(Config.self, from: Data(bad.utf8)) } catch { print("SCHEMA ERR:", error) }

let broken = """
{
  version: 1,
  layouts: [
    { name: "x", zones: [ { name: "a", x: 0 y: 0 } ] }
  ]
}
"""
do { _ = try dec.decode(Config.self, from: Data(broken.utf8)) } catch { print("SYNTAX ERR:", error) }

do {
  let tree = try JSONSerialization.jsonObject(with: Data(src.utf8), options: [.json5Allowed, .fragmentsAllowed])
  let dict = tree as? [String: Any]
  print("TREE OK keys:", dict?.keys.sorted() ?? [])
} catch { print("TREE FAIL", error) }

let plain = #"{"version":1,"layouts":[{"name":"g","zones":[{"name":"a","x":0,"y":0,"width":1,"height":1}]}]}"#
do { _ = try dec.decode(Config.self, from: Data(plain.utf8)); print("PLAIN JSON under JSON5 decoder: OK") }
catch { print("PLAIN FAIL", error) }

let a = 1.0/3.0, b = 2.0/3.0
print("3*(1/3)==1:", a+a+a == 1.0, " 1-2/3 == 1/3:", (1.0 - b) == a)
