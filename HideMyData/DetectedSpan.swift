import Foundation

struct DetectedSpan: Identifiable, Equatable {
    let id = UUID()
    let category: String
    let text: String
    let start: Int
    let end: Int
    let confidence: Float
}

enum HMDError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let s) = self { return s }
        return nil
    }
}

/// Anything that can find PII spans in a block of text. `PIIDetector` (the on-device model)
/// is the production implementation; tests inject a deterministic stub.
@MainActor
protocol PIIDetecting {
    func detect(_ text: String) async -> Result<[DetectedSpan], Error>
}
