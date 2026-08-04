import Foundation

/// Moving a pre-1.0 layout to where layouts live now.
///
/// This is the first thing the tree was built for. Migrating is a transform over
/// a loose tree — add a key, keep everything else exactly as the user left it,
/// render — rather than decoding into a struct from 2026 and encoding into a
/// struct from now, which is how a project ends up with every historical version
/// of its model living in the source forever.
///
/// It is also why the version key exists at all. Today it buys one thing: a file
/// from the future can be recognised as such and refused with a sentence instead
/// of a pile of schema errors.
enum LayoutMigration {

    /// The version this app writes and understands.
    static let currentVersion = 1

    /// Copies a pre-1.0 layout to `destination`, once.
    ///
    /// **The old file is not deleted, moved, or touched in any way.** That is
    /// the backup, and it is a better one than a `.bak` next to it: it is the
    /// original, in the place the user's muscle memory already knows, and no
    /// code here can corrupt it because no code here writes to it.
    ///
    /// - Returns: whether anything was migrated.
    @discardableResult
    static func migrateIfNeeded(from legacy: URL,
                                to destination: URL,
                                using fileManager: FileManager = .default) -> Bool {
        guard !fileManager.fileExists(atPath: destination.path) else { return false }
        guard fileManager.fileExists(atPath: legacy.path) else { return false }

        do {
            let old = try String(contentsOf: legacy, encoding: .utf8)
            let migrated = migrate(try LayoutSyntax.parse(old), from: legacy)
            try LayoutFile.write(Data(LayoutSyntax.render(migrated).utf8), to: destination)

            Log.write("layout: migrated \(legacy.path)")
            Log.write("layout:       to \(destination.path)")
            Log.write("layout: the old file was left exactly where it was, and is no longer read")
            return true
        } catch {
            // A pre-1.0 file that cannot be read is not a reason to refuse to
            // start. The new file simply does not get created from it, the
            // built-in layout is used, and the reason is here.
            Log.write("layout: could NOT migrate \(legacy.path) — \(error)")
            return false
        }
    }

    /// v0 → v1, over the tree.
    ///
    /// v0 is `{ name, zones }` with no version key. v1 is the same thing with
    /// `version: 1` in front of it — the shape stays flat on purpose. Wrapping a
    /// single layout in `layouts: [ … ]` would make everybody write a level of
    /// nesting to get one layout, which is the exact objection §4 of the plan
    /// raises against TOML: structure that hides the geometry and buys nothing
    /// yet. When several layouts arrive they arrive as an *alternative* form,
    /// not as a replacement, so this does not need doing twice.
    static func migrate(_ document: LayoutSyntax.Document, from legacy: URL) -> LayoutSyntax.Document {
        guard case .object(let members) = document.root else { return document }
        guard !members.contains(where: { $0.key == "version" }) else { return document }

        var migrated = document
        migrated.root = .object([versionMember(currentVersion)] + members.map(withoutLegacyKeys))

        // Two lines so that a file which appears out of nowhere explains
        // itself. Whoever opens this wants to know where it came from and
        // whether the old one still matters.
        if migrated.preamble.isEmpty {
            migrated.preamble = [
                "// Zonas layout, moved here from \(abbreviate(legacy)).",
                "// The old file was left where it was and is no longer read.",
            ]
        }
        return migrated
    }

    /// Keys v0 wrote that v1 does not have.
    ///
    /// Only `id`, and dropping it is the entire reason a migration is a
    /// different thing from "keep everything you do not recognise". That rule is
    /// right for keys from the *future* — an older Zonas must not eat what a
    /// newer one wrote. `id` is not from the future: it is a key this project
    /// deliberately removed, because the app used to fill the file with UUIDs
    /// nobody had typed and they were never useful as identity anyway. Carrying
    /// them across would mean the first thing a migrating user sees in their new
    /// file is four UUIDs they did not write, which is the complaint the removal
    /// was answering.
    ///
    /// Found by migrating a real file and reading the result.
    private static let removedInV1 = ["id"]

    private static func withoutLegacyKeys(_ member: LayoutSyntax.Member) -> LayoutSyntax.Member {
        guard member.key == "zones", case .array(let zones) = member.node else { return member }

        var cleaned = member
        cleaned.node = .array(zones.map { zone in
            guard case .object(let fields) = zone.node else { return zone }
            var stripped = zone
            stripped.node = .object(fields.filter { !removedInV1.contains($0.key) })
            return stripped
        })
        return cleaned
    }

    private static func versionMember(_ version: Int) -> LayoutSyntax.Member {
        LayoutSyntax.Member(
            key: "version",
            node: .number(String(version)),
            comments: LayoutSyntax.Comments(
                trailing: "// the format, not the app",
                blankLineBefore: false))
    }

    private static func abbreviate(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home)
            ? "~" + url.path.dropFirst(home.count)
            : url.path
    }
}

extension Layout {

    /// Refuses a file written by a version of the app that does not exist yet.
    ///
    /// Without this, a v2 file meets a v1 reader and produces whatever pile of
    /// schema errors its new keys happen to cause — which reads as "your file is
    /// broken" when the truth is "this copy of Zonas is old".
    static func checkVersion(_ document: LayoutSyntax.Document) throws {
        guard case .object(let members) = document.root,
              let version = members.first(where: { $0.key == "version" }) else { return }
        guard case .number(let literal) = version.node, let number = Int(literal) else {
            throw LayoutSchemaError(line: version.line, message: "version has to be a whole number")
        }
        guard number <= LayoutMigration.currentVersion else {
            throw LayoutSchemaError(
                line: version.line,
                message: "this file says version \(number) and this copy of Zonas "
                    + "only understands \(LayoutMigration.currentVersion) — update Zonas")
        }
    }
}
