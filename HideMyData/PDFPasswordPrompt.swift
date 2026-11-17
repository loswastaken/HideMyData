import AppKit

/// Asks for a PDF's open password. Returns `nil` when the user cancels.
/// `previousAttemptFailed` is true when the last password that was tried did not unlock the file.
typealias PDFPasswordProvider = @MainActor (_ documentName: String, _ previousAttemptFailed: Bool) -> String?

enum PDFPasswordPrompt {
    /// Modal NSAlert with a secure text field. Used by the app; tests inject their own provider.
    @MainActor
    static func ask(documentName: String, previousAttemptFailed: Bool) -> String? {
        let alert = NSAlert()
        alert.alertStyle = previousAttemptFailed ? .warning : .informational
        alert.messageText = previousAttemptFailed
            ? "Incorrect password for “\(documentName)”"
            : "“\(documentName)” is password protected"
        alert.informativeText = previousAttemptFailed
            ? "The password did not unlock the document. Try again, or cancel."
            : "Enter the password to open this PDF."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Password"
        alert.accessoryView = field
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }
}
