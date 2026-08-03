import AppKit
import ServiceManagement

/// Automatic launch at login.
///
/// The system records it in Background Task Management, and it records it by
/// **bundle id** —`2.uy.com.fcstudio.zonas`—, with no cdhash anywhere. It is
/// the opposite of TCC: recompiling does not break it. Set it once and never
/// touch it again.
///
/// There is a trap, and it is why everything goes through `isInstalledCopy`:
/// BTM keeps a single entry per bundle id, and the field holding the path —the
/// one macOS will open at login— is rewritten with the path of the last bundle
/// that talked to `SMAppService`. **Merely READING `status` is enough to
/// trigger it.** If that query came from the copy in `.build/`, the login item
/// would be left pointing at a bundle that the next build deletes, and after a
/// restart nothing would launch, without a single visible error. That is why
/// the development copy does not touch the API, not even to ask.
enum LaunchAtLogin {

    /// Only the copy in `/Applications` gets a say in front of BTM.
    static var isInstalledCopy: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
    }

    /// Will it launch on its own? Also `false` when asking is out of place.
    static var isEnabled: Bool {
        isInstalledCopy && SMAppService.mainApp.status == .enabled
    }

    /// For the log and the menu.
    ///
    /// Never cached in `UserDefaults`: the truth lives in the system, the user
    /// can turn it off from Settings and no notification whatsoever tells the
    /// app about it.
    static var statusText: String {
        guard isInstalledCopy else {
            return "not applicable, running from \(Bundle.main.bundlePath)"
        }
        switch SMAppService.mainApp.status {
        case .enabled:          return "enabled"
        case .notRegistered:    return "off"
        case .requiresApproval: return "needs approval in Settings"
        case .notFound:         return "no record"
        @unknown default:       return "unknown"
        }
    }

    /// Turns it on or off. Returns the **real** state afterwards, which may not
    /// be the one requested: if the user turned it off by hand in Settings,
    /// `register()` fails with `SMAppServiceErrorDomain 1` and no API can undo
    /// that — only the panel can. `register()` on something already registered
    /// is idempotent.
    @discardableResult
    static func set(_ on: Bool) -> Bool {
        guard isInstalledCopy else {
            Log.write("startup: ignored, this copy is not the one in /Applications")
            return false
        }
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Log.write("startup: \(on ? "registered" : "removed") — now \(statusText)")
        } catch let error as NSError {
            Log.write("startup: \(on ? "register" : "unregister") failed — "
                      + "\(error.domain) \(error.code): \(error.localizedDescription)")
            if on, error.domain == "SMAppServiceErrorDomain", error.code == 1 {
                openSettings()
            }
        }
        return isEnabled
    }

    static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
