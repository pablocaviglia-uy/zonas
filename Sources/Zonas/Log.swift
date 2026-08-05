import Foundation

/// File logging.
///
/// A menu bar app has no console to watch, and the moment that matters —the
/// drag— is exactly when you can't be reading anything on screen. Check it
/// afterwards with:
///
/// ```
/// tail -f ~/Library/Logs/Zonas.log
/// ```
///
/// What gets logged are **state transitions**, not every event: a
/// `mouseDragged` arrives dozens of times per second and would fill the file
/// with noise without adding any information.
enum Log {

    /// Where the log goes.
    ///
    /// It is a `var` for exactly one reason: the test suite points it at a
    /// scratch file before it runs. This is the file you open when something is
    /// actually wrong, and a test run leaving a dozen
    /// `layout: FAILED to read /var/folders/…/zonas-tests-…` lines in the middle
    /// of it costs the next person a double take at the worst possible moment.
    /// Nothing in the app ever assigns it.
    static var url: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Logs/Zonas.log")
    }() {
        // A different file has not been told what day it is. Not a test hook:
        // the day rule below is a property of the file being written to, so
        // pointing at another one has to forget the old one's.
        didSet { queue.sync { lastDay = nil } }
    }

    private static let queue = DispatchQueue(label: "uy.com.fcstudio.zonas.log")

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// The day the last line was written on, so a new one announces itself.
    ///
    /// Guarded by `queue`, like everything else that touches the file.
    private static var lastDay: String?

    /// Today, spelled the way the rule spells it.
    static var today: String { dayFormatter.string(from: Date()) }

    /// Waits for everything already queued to reach the file.
    ///
    /// Writing is asynchronous so that a drag never waits on a disk, which
    /// means a test that writes and then reads is racing itself. The app never
    /// reads its own log and so never needs this.
    static func waitForWrites() { queue.sync {} }

    /// A `-- 2026-08-05 --` rule whenever the date changes, and nothing on the
    /// lines themselves.
    ///
    /// The lines carry the time only, because the file is read by tailing it
    /// while something is going wrong and a date on every line is thirteen
    /// characters of noise in a file whose whole discipline is not having any.
    ///
    /// But a file that spans days with no date in it cannot be filtered by time
    /// at all, and that is not hypothetical: chasing a drag that ended early,
    /// `awk '$1 >= "08:19:00"'` quietly matched **every previous day's**
    /// 08:19-to-23:59 as well, which made the timestamps look out of order and
    /// bought an entirely wrong theory about two processes writing at once. One
    /// line per day is the cheapest thing that makes that impossible.
    private static func dayRule(for now: Date) -> String {
        let today = dayFormatter.string(from: now)
        guard today != lastDay else { return "" }
        let first = lastDay == nil
        lastDay = today
        return "\(first ? "" : "\n")-- \(today) --\n"
    }

    static func write(_ message: String) {
        let now = Date()
        let line = "\(timeFormatter.string(from: now))  \(message)\n"
        queue.async {
            guard let data = (dayRule(for: now) + line).data(using: .utf8) else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)

            // O_APPEND, not FileHandle.seekToEnd(): every write is atomic and
            // lands at the end even if another process is writing. With
            // seekToEnd the build leaves two instances alive for an instant
            // —`pkill` signals and comes back— and they clobber each other's
            // line.
            //
            // It also avoids the previous fallback, which used
            // `data.write(to:)` when the file didn't exist: that doesn't
            // append, it REPLACES. Deleting the log with the app running made
            // the next line wipe out everything written before it.
            let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            guard fd >= 0 else { return }
            defer { close(fd) }
            // Module-qualified on purpose: an unqualified `write` inside this
            // enum resolves to `Log.write(_:)` above and shadows the POSIX one.
            _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        }
    }
}
