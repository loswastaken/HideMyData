import Foundation

/// A detected span that could not be turned into a rectangle on its page.
struct UnlocatedSpan: Equatable {
    let pageIndex: Int
    let category: String
    let text: String
}

/// What a detection run actually achieved. Nothing is dropped silently.
struct PDFDetectionReport: Equatable {
    /// Distinct spans returned by the detector (native text and OCR text), over all pages.
    var detectedSpanCount = 0
    /// Redaction rectangles that were created AND confirmed attached to their page.
    var placedRectCount = 0
    /// Spans that were detected but could not be located on the page.
    var unlocatedSpans: [UnlocatedSpan] = []
    /// 0-based pages that could not be analysed at all (no native text, and OCR failed).
    var skippedPages: [Int] = []
    /// 0-based pages with native text whose pixels could not be checked (OCR failed), so
    /// anything that exists only as pixels on them was not seen.
    var pagesNotPixelChecked: [Int] = []
    /// 0-based pages where neither the native text nor OCR found any text.
    var pagesWithoutText: [Int] = []
    /// Rectangles that PDFKit refused to attach to their page.
    var failedAttachCount = 0

    /// True when something may still be unredacted; the user must be told before saving.
    var needsManualReview: Bool {
        !unlocatedSpans.isEmpty || !skippedPages.isEmpty || !pagesNotPixelChecked.isEmpty || failedAttachCount > 0
    }

    /// Short, human-readable description of what needs manual attention, or nil.
    var reviewSummary: String? {
        guard needsManualReview else { return nil }
        var parts: [String] = []
        if !unlocatedSpans.isEmpty {
            let pages = Self.pageList(unlocatedSpans.map(\.pageIndex))
            let n = unlocatedSpans.count
            parts.append("\(n) detected item\(n == 1 ? "" : "s") could not be located (\(pages))")
        }
        if !skippedPages.isEmpty {
            let n = skippedPages.count
            parts.append("\(n) page\(n == 1 ? "" : "s") could not be read (\(Self.pageList(skippedPages)))")
        }
        if !pagesNotPixelChecked.isEmpty {
            parts.append("text recognition failed on \(Self.pageList(pagesNotPixelChecked)), so text that exists only as image was not checked")
        }
        if failedAttachCount > 0 {
            parts.append("\(failedAttachCount) redaction\(failedAttachCount == 1 ? "" : "s") could not be placed")
        }
        return parts.joined(separator: "; ") + " — redact manually"
    }

    /// Non-blocking notice: pages on which nothing readable was found.
    var notice: String? {
        guard !pagesWithoutText.isEmpty else { return nil }
        return "Nothing readable on \(Self.pageList(pagesWithoutText)) — check visually"
    }

    static func pageList(_ indices: [Int]) -> String {
        let pages = Array(Set(indices)).sorted().map { String($0 + 1) }
        return (pages.count == 1 ? "page " : "pages ") + pages.joined(separator: ", ")
    }
}
