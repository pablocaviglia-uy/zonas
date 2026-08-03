import Foundation
import Security

/// Signing fingerprint of the **live** process: its cdhash and its designated
/// requirement.
///
/// This is exactly what TCC compares against the requirement it stored when the
/// permission was granted. Logging it at startup closes this app's most
/// confusing failure in a single glance: if today's cdhash isn't the one from
/// the previous run, the permission is already broken and there is nothing to
/// investigate — the switch in Settings will still be on, lying.
///
/// It looks at the running process and not at the bundle on disk on purpose:
/// that distinguishes "an old build is running" from "the TCC entry is stale",
/// which look identical from the outside.
func signatureFingerprint() -> String {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return "?" }

    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
          let staticCode else { return "?" }

    var info: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode,
                                        SecCSFlags(rawValue: kSecCSSigningInformation),
                                        &info) == errSecSuccess,
          let fields = info as? [String: Any] else { return "?" }

    let cdhash = (fields[kSecCodeInfoUnique as String] as? Data)
        .map { $0.map { String(format: "%02x", $0) }.joined() } ?? "?"

    var requirement: SecRequirement?
    var text = "?"
    if SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
       let requirement {
        var string: CFString?
        if SecRequirementCopyString(requirement, [], &string) == errSecSuccess,
           let string { text = string as String }
    }

    return "cdhash=\(cdhash) requirement=\(text)"
}
