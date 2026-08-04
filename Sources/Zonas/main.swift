import AppKit

// Arguments mean the terminal, and the terminal gets an answer and an exit code
// rather than a menu bar icon. Nothing of AppKit's is started down this path, so
// `zonas check` in a script does not flash an app into existence.
//
// One binary and not two: a second executable would need its own signing, its
// own notarization and its own place in the disk image, in order to run the same
// three hundred lines that are already in this one.
let arguments = Array(CommandLine.arguments.dropFirst())
if !arguments.isEmpty {
    exit(Command.run(arguments))
}

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.run()
