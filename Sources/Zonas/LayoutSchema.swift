import Foundation

/// Something wrong with the *meaning* of the file, and where to go look.
///
/// Told apart from `LayoutSyntax.ParseError`, which is about the file not being
/// JSON5 at all. Both carry a line, because both are things the user is going to
/// have to go and fix, and "the layout is invalid" without a line number is
/// barely better than saying nothing.
struct LayoutSchemaError: Error, CustomStringConvertible, Equatable {
    let line: Int
    let message: String

    var description: String { "line \(line): \(message)" }
}

extension Layout {

    /// Reads a layout out of a parsed file.
    ///
    /// This is the second of the five jobs the one parser does. It takes the
    /// tree rather than the bytes, which is what buys the line numbers — a
    /// `JSONDecoder` can only offer a byte offset into the data, and nobody has
    /// ever counted to byte 431 of their own config file.
    ///
    /// Keys it does not recognise are ignored rather than rejected. They are
    /// still in the tree, so a write gives them back untouched: a file written
    /// for a newer version of the app has to keep working in an older one, and
    /// the older one must not eat what it did not understand.
    init(_ document: LayoutSyntax.Document) throws {
        guard case .object(let members) = document.root else {
            throw LayoutSchemaError(line: document.rootLine,
                                    message: "the file has to hold one object, in braces")
        }

        guard let named = members.first(where: { $0.key == "name" }) else {
            throw LayoutSchemaError(line: document.rootLine, message: "the layout needs a name")
        }
        guard case .string(let name) = named.node else {
            throw LayoutSchemaError(line: named.line, message: "name has to be text, in quotes")
        }

        guard let listed = members.first(where: { $0.key == "zones" }) else {
            throw LayoutSchemaError(line: document.rootLine, message: "the layout needs a list of zones")
        }
        guard case .array(let elements) = listed.node else {
            throw LayoutSchemaError(line: listed.line, message: "zones has to be a list, in brackets")
        }

        let zones = try elements.map { try Zone($0) }

        // Names have to be unique, and this is where that is enforced.
        //
        // The name is the handle: it is what the overlay draws over the zone,
        // what an error message can refer to, and what the editor will use to
        // keep track of a zone across a reload. Two zones called "Left" is
        // already a bug you can see on screen — this just says so, with both
        // line numbers, instead of letting you find out later.
        var firstSeen: [String: Int] = [:]
        for (zone, element) in zip(zones, elements) {
            if let earlier = firstSeen[zone.name] {
                throw LayoutSchemaError(
                    line: element.line,
                    message: "there is already a zone called \"\(zone.name)\", on line \(earlier)")
            }
            firstSeen[zone.name] = element.line
        }

        let defaults = try Defaults(members.first { $0.key == "defaults" })

        self.init(name: name,
                  zones: zones,
                  gap: defaults.gap,
                  margin: defaults.margin,
                  modifier: defaults.modifier,
                  ignored: try Layout.ignored(members.first { $0.key == "ignore" }))
    }

    /// The `ignore` list: bundle identifiers of applications to leave alone.
    ///
    /// It sits at the root rather than inside `defaults`, and that is a decision
    /// about what happens in Stage 3. `defaults` is the block §4 describes as
    /// applying to every layout *and overridable by any one of them* — a gap or
    /// a modifier per layout is a sensible thing to want. "Which applications
    /// Zonas will not touch" is not a property of a set of rectangles, and
    /// nesting it under a heading that promises per-layout overrides would
    /// promise something there is no reason to build.
    ///
    /// An entry naming an application that is not installed is not an error. It
    /// is the whole point of §6's bet applied one level down: the file describes
    /// the world, including the parts of it that are not plugged in or not
    /// installed on the machine reading it.
    private static func ignored(_ member: LayoutSyntax.Member?) throws -> Set<String> {
        guard let member else { return [] }
        guard case .array(let elements) = member.node else {
            throw LayoutSchemaError(
                line: member.line,
                message: "ignore has to be a list of bundle identifiers, in brackets")
        }

        var identifiers: Set<String> = []
        for element in elements {
            guard case .string(let identifier) = element.node, !identifier.isEmpty else {
                throw LayoutSchemaError(
                    line: element.line,
                    message: "a bundle identifier has to be text, in quotes — "
                        + "\"com.apple.Safari\", which `zonas apps` will print for you")
            }
            identifiers.insert(identifier)
        }
        return identifiers
    }

    /// The `defaults` block, or the built-in values when there is none.
    ///
    /// It is a block rather than three loose keys because of where this is
    /// going: §4's design has it apply to every layout, with any layout free to
    /// override any of it. Reading it from one place now means multiple layouts
    /// only has to add the override, not move the keys.
    private struct Defaults {
        var gap = Layout.defaultGap
        var margin = Layout.defaultMargin
        var modifier = Modifier.shift

        init(_ member: LayoutSyntax.Member?) throws {
            guard let member else { return }
            guard case .object(let settings) = member.node else {
                throw LayoutSchemaError(line: member.line,
                                        message: "defaults has to be an object, in braces")
            }

            for setting in settings {
                switch setting.key {
                case "gap": gap = try points(setting)
                case "margin": margin = try points(setting)
                case "modifier": modifier = try key(setting)
                default: break   // a key from a newer version; the tree keeps it
                }
            }
        }

        private func points(_ member: LayoutSyntax.Member) throws -> CGFloat {
            guard case .number(let literal) = member.node,
                  let value = Double(literal), value >= 0, value.isFinite else {
                throw LayoutSchemaError(line: member.line,
                                        message: "\(member.key) has to be a number of points, zero or more")
            }
            return CGFloat(value)
        }

        private func key(_ member: LayoutSyntax.Member) throws -> Modifier {
            guard case .string(let name) = member.node,
                  let modifier = Modifier(rawValue: name) else {
                throw LayoutSchemaError(
                    line: member.line,
                    message: "modifier has to be one of "
                        + Modifier.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", "))
            }
            return modifier
        }
    }
}

extension Zone {

    init(_ element: LayoutSyntax.Element) throws {
        guard case .object(let members) = element.node else {
            throw LayoutSchemaError(line: element.line, message: "a zone has to be an object, in braces")
        }

        func member(_ key: String) throws -> LayoutSyntax.Member {
            guard let found = members.first(where: { $0.key == key }) else {
                throw LayoutSchemaError(line: element.line, message: "this zone has no \(key)")
            }
            return found
        }

        let named = try member("name")
        guard case .string(let name) = named.node, !name.isEmpty else {
            throw LayoutSchemaError(line: named.line, message: "a zone's name has to be text, in quotes")
        }

        func fraction(_ key: String) throws -> Double {
            let found = try member(key)
            guard let value = Zone.fraction(of: found.node), value.isFinite else {
                throw LayoutSchemaError(
                    line: found.line,
                    message: "\(key) has to be a fraction of the screen: 0.25, \"1/4\" or \"25%\"")
            }
            return value
        }

        let width = try fraction("width")
        let height = try fraction("height")
        // A zone with no area cannot be drawn, cannot be aimed at, and would
        // hand the Accessibility API a rectangle no window can occupy.
        guard width > 0, height > 0 else {
            throw LayoutSchemaError(line: element.line,
                                    message: "a zone needs a width and a height above zero")
        }

        self.init(name: name,
                  x: try fraction("x"),
                  y: try fraction("y"),
                  width: width,
                  height: height)
    }

    /// Reads a fraction of the screen: `0.25`, `"1/4"` or `"25%"`.
    ///
    /// Ratios are not sugar. Three columns written as `0.3333` leave a sliver on
    /// the right edge that you notice eventually and never manage to find,
    /// because the mistake is invisible in the file — `"1/3"` is exact, and it
    /// says what you meant. The same three written as ratios add up to precisely
    /// 1, which is the property the editor's snapping is going to rely on.
    ///
    /// Not here yet, and worth knowing before you try it: pixel values like
    /// `1280px` and arithmetic like `1/2 - 1/16`. Both are in §5 of the plan.
    /// Pixels in particular cannot live in this function at all — they need to
    /// know how wide the screen is, which nothing here does.
    static func fraction(of node: LayoutSyntax.Node) -> Double? {
        switch node {
        case .number(let literal):
            // `.25` is legal JSON5 and Double() reads it, but the leading zero
            // costs nothing to tolerate either way.
            return Double(literal)

        case .string(let text):
            let text = text.trimmingCharacters(in: .whitespaces)
            if text.hasSuffix("%") {
                return Double(text.dropLast()).map { $0 / 100 }
            }
            let parts = text.split(separator: "/", maxSplits: 1)
            guard parts.count == 2,
                  let numerator = Double(parts[0].trimmingCharacters(in: .whitespaces)),
                  let denominator = Double(parts[1].trimmingCharacters(in: .whitespaces)),
                  denominator != 0 else { return nil }
            return numerator / denominator

        default:
            return nil
        }
    }
}
