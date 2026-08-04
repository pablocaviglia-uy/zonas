import AppKit
import Foundation

/// A target zone, stored as fractions (0…1) of the screen's usable area rather
/// than as pixels.
///
/// Keeping them relative is what lets the same layout work just as well on the
/// laptop screen and on an external monitor of a different resolution, without
/// having to redraw it for each one.
///
/// **There is deliberately no `id`.** There was one, and Swift synthesized
/// `encode(to:)` over it, so every save put UUIDs nobody had typed into a file
/// whose whole point is being edited by hand. They were not even useful as
/// identity: a fresh one was minted on every reload of a file that didn't carry
/// them, so nothing could be tracked across a reload anyway.
///
/// In the file the handle is `name`, unique within its layout. The stable
/// identity the editor needs is a different thing, it lives in memory, and it
/// never reaches disk.
struct Zone: Codable, Equatable {
    var name: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    /// Translates the zone into a concrete rectangle inside a screen area.
    func rect(in area: CGRect) -> CGRect {
        CGRect(x: area.origin.x + area.width * x,
               y: area.origin.y + area.height * y,
               width: area.width * width,
               height: area.height * height)
    }
}

/// A set of zones that are used together.
struct Layout: Codable {
    var name: String
    var zones: [Zone]

    /// Three columns 25 / 50 / 25: the middle one for the window being worked
    /// on and the side ones for whatever is being consulted. It is the layout
    /// that pays off the most on a wide monitor, and it serves as a starting
    /// point until the zone editor exists.
    static let threeColumns = Layout(
        name: "Three Columns",
        zones: [
            Zone(name: "Left",   x: 0.00, y: 0, width: 0.25, height: 1),
            Zone(name: "Center", x: 0.25, y: 0, width: 0.50, height: 1),
            Zone(name: "Right",  x: 0.75, y: 0, width: 0.25, height: 1),
        ]
    )
}

/// Loads and saves the layout on disk.
///
/// For now it is a loose JSON file that can be edited by hand — enough to prove
/// the concept, and it makes the graphical editor unnecessary at this stage.
final class ZoneStore {
    static let shared = ZoneStore()

    private let url: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("Zonas/layout.json")
    }()

    private(set) var layout: Layout

    private init() {
        layout = ZoneStore.read(url) ?? .threeColumns
    }

    /// Path of the file, so it can be opened from the menu.
    var fileURL: URL { url }

    /// Reads the layout from disk. Returns `nil` if there is no file or if it
    /// couldn't be parsed, and in the second case **it leaves that written in
    /// the log**.
    ///
    /// The `try?`s that used to be here swallowed the error: one comma too many
    /// in the file looked exactly the same as having no file at all, and the
    /// app fell back to the built-in layout without saying a word.
    private static func read(_ url: URL) -> Layout? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder().decode(Layout.self, from: Data(contentsOf: url))
        } catch {
            Log.write("layout: FAILED to read \(url.path) — \(error)")
            Log.write("layout: using the built-in one; the file is NOT touched")
            return nil
        }
    }

    /// Writes the built-in layout only if there is no file yet.
    ///
    /// This is what gets called at startup. It used to be a bare `save()`, and
    /// that clobbered the user's file every time parsing failed: a typo took
    /// all of their zones with it. With launch at login that would happen on
    /// the next login, when nobody is watching any more.
    func createIfMissing() {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        save()
    }

    /// Writes the current layout, creating the folder if needed.
    @discardableResult
    func save() -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(layout) else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        return (try? data.write(to: url)) != nil
    }

    func reload() {
        layout = ZoneStore.read(url) ?? .threeColumns
    }

    /// The zone under a point, in CG coordinates.
    ///
    /// When zones overlap, **the smallest** one containing the point wins. It
    /// is the rule that makes a layout with one big zone in the background and
    /// others on top of it usable: without it the big one would eat every
    /// target.
    func zone(under point: CGPoint, in area: CGRect) -> (zone: Zone, rect: CGRect)? {
        layout.zones
            .map { (zone: $0, rect: $0.rect(in: area)) }
            .filter { $0.rect.contains(point) }
            .min { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }
    }
}
