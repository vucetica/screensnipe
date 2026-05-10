import AppKit
import os

@MainActor
enum ErrorReporter {
    private static let logger = Logger(subsystem: "app.screensnipe", category: "errors")

    /// Log and show an alert for user-facing persistence failures.
    static func report(_ error: Error, context: String) {
        logger.error("[\(context)] \(error.localizedDescription)")
        let alert = NSAlert()
        alert.messageText = context
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Log without UI — for non-critical failures where silent logging is sufficient.
    static func log(_ error: Error, context: String) {
        logger.error("[\(context)] \(error.localizedDescription)")
    }
}
