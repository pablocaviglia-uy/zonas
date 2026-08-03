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

    static let url: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Logs/Zonas.log")
    }()

    private static let queue = DispatchQueue(label: "uy.com.fcstudio.zonas.log")

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func write(_ message: String) {
        let line = "\(timeFormatter.string(from: Date()))  \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
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
