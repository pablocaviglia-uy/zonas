import AppKit
import Foundation
let d = JSONDecoder()
d.allowsJSON5 = true
_ = try? JSONSerialization.jsonObject(with: Data("{a:1}".utf8), options: [.json5Allowed])
print("compiles+runs at macOS 14 target; allowsJSON5 =", d.allowsJSON5)
print("levels: floating=", NSWindow.Level.floating.rawValue,
      "mainMenu=", NSWindow.Level.mainMenu.rawValue,
      "popUpMenu=", NSWindow.Level.popUpMenu.rawValue,
      "normal=", NSWindow.Level.normal.rawValue,
      "screenSaver=", NSWindow.Level.screenSaver.rawValue)
