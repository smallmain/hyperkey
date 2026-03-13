import ApplicationServices
import Foundation

@MainActor
enum Accessibility {
    /// Prompt for accessibility permission if needed, then poll asynchronously
    /// until the app becomes trusted.
    static func waitForPermission(onGranted: @escaping @MainActor () -> Void) {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary

        if AXIsProcessTrustedWithOptions(options) {
            onGranted()
            return
        }

        fputs("hyperkey: waiting for Accessibility permission...\n", stderr)
        pollUntilTrusted(onGranted: onGranted)
    }

    private static func pollUntilTrusted(onGranted: @escaping @MainActor () -> Void) {
        guard !AXIsProcessTrusted() else {
            fputs("hyperkey: Accessibility permission granted.\n", stderr)
            onGranted()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            Task { @MainActor in
                pollUntilTrusted(onGranted: onGranted)
            }
        }
    }
}
