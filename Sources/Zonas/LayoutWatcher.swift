import Foundation

/// Notices when the layout file changes on disk.
///
/// This is what makes the file the truth rather than a starting point: you edit
/// it in your editor, you save, and the zones change. Without it the file is
/// just an import format with a menu item next to it.
///
/// ### Why there is more than one source
///
/// A `DispatchSource` on a file watches an **inode**, not a path, and almost
/// nothing that writes a config file writes it in place. `vim :w`, `git
/// checkout`, a dotfiles manager relinking, and this app's own
/// `LayoutFile.write` all end with a rename over the target — after which the
/// descriptor being watched refers to a file that no longer has a name.
///
/// Measured, with a spike that performs the four ways a config file gets
/// written (`docs/prototypes/watch.swift`):
///
/// ```
/// 1. in-place write ....... file source fires, directory silent
/// 2. atomic replace ....... file source fires .delete, then must re-arm
/// 3. mv over it ........... same, twice
/// 4. delete then recreate . file source fires .delete — and the re-arm FAILS,
///                           because the file does not exist yet
/// ```
///
/// Case 4 is the whole argument. With only a source on the file, one
/// delete-then-recreate leaves the watcher permanently deaf, silently, and the
/// user's next save simply does nothing forever. The source on the **directory**
/// is what brings it back, and it is why re-arming has to be something that can
/// be retried rather than something attempted once.
final class LayoutWatcher {

    private let url: URL
    private let onChange: () -> Void

    private let queue = DispatchQueue(label: "uy.com.fcstudio.zonas.watch")
    private var fileSource: DispatchSourceFileSystemObject?
    private var directorySources: [DispatchSourceFileSystemObject] = []
    private var pendingNotification: DispatchWorkItem?
    private var rearmAttempts = 0

    /// Long enough to swallow the two or three events one save produces, short
    /// enough that saving still feels like it did something.
    private let settleTime: DispatchTimeInterval = .milliseconds(120)

    private let maxRearmAttempts = 10

    /// - Parameter onChange: called on the main queue, after the writes have
    ///   settled. It is a nudge, not a payload: the file has to be read again
    ///   anyway, and this way one save produces one read.
    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    deinit { stop() }

    func start() {
        queue.async { [self] in
            armDirectories()
            armFile()
        }
    }

    func stop() {
        queue.sync { [self] in
            pendingNotification?.cancel()
            pendingNotification = nil
            fileSource?.cancel()
            fileSource = nil
            directorySources.forEach { $0.cancel() }
            directorySources = []
        }
    }

    // MARK: - Arming

    /// The directories worth watching.
    ///
    /// The file's own, always. And when the config is a symlink out of a
    /// dotfiles repo — which is the arrangement this whole feature exists for —
    /// the link's directory as well, so that re-pointing the link is noticed and
    /// not just changes to whatever it currently points at.
    private var directoriesToWatch: [URL] {
        let target = url.resolvingSymlinksInPath()
        var directories = [target.deletingLastPathComponent()]

        let linkDirectory = url.deletingLastPathComponent().resolvingSymlinksInPath()
        if linkDirectory.path != directories[0].path {
            directories.append(linkDirectory)
        }
        return directories
    }

    private func armDirectories() {
        directorySources.forEach { $0.cancel() }
        directorySources = []

        for directory in directoriesToWatch {
            let descriptor = open(directory.path, O_EVTONLY)
            guard descriptor >= 0 else {
                Log.write("watch: cannot watch \(directory.path)")
                continue
            }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write], queue: queue)

            source.setEventHandler { [weak self] in
                guard let self else { return }
                // Something happened in the directory. If the file source died
                // because the file was momentarily gone, this is what brings it
                // back — see case 4 in the note above.
                if fileSource == nil {
                    rearmAttempts = 0
                    armFile()
                }
                scheduleNotification()
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            directorySources.append(source)
        }
    }

    private func armFile() {
        fileSource?.cancel()
        fileSource = nil

        // Re-resolved every time: the link may now point somewhere else.
        let target = url.resolvingSymlinksInPath()
        let descriptor = open(target.path, O_EVTONLY)
        guard descriptor >= 0 else {
            scheduleRearm()
            return
        }
        rearmAttempts = 0

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke],
            queue: queue)

        source.setEventHandler { [weak self] in
            guard let self, let source = fileSource else { return }
            let events = source.data

            if events.contains(.delete) || events.contains(.rename) || events.contains(.revoke) {
                // The name now points at a different file, which is what a save
                // looks like from here. Follow it.
                rearmAttempts = 0
                armFile()
            }
            scheduleNotification()
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        fileSource = source
    }

    /// The file was not there. It usually will be in a moment — that is what a
    /// delete-then-recreate looks like from this side — so try again, a bounded
    /// number of times. If it never comes back, the directory source is still
    /// listening and will arm it the moment it does.
    private func scheduleRearm() {
        guard rearmAttempts < maxRearmAttempts else {
            Log.write("watch: \(url.lastPathComponent) is gone; waiting for it to come back")
            return
        }
        rearmAttempts += 1
        queue.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            self?.armFile()
        }
    }

    // MARK: - Notifying

    /// One save produces two or three events. This turns them into one read.
    private func scheduleNotification() {
        pendingNotification?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { self.onChange() }
        }
        pendingNotification = work
        queue.asyncAfter(deadline: .now() + settleTime, execute: work)
    }
}
