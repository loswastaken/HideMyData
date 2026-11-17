import Foundation
import ImageIO
import PDFKit

/// Detection pipeline. Every page is OCR'd, always: the native text layer can be missing,
/// partial, misplaced or mis-sized relative to the pixels (scans with an invisible OCR layer,
/// fax headers, Bates stamps), and the export burns in pixels, so pixels are what must be covered.
///
/// Per page:
/// 1. native text → detector → rects from the validated selection (or text search), plus the
///    OCR boxes of the same text;
/// 2. OCR text → detector → rects from the OCR boxes, plus native-layer matches of the same text;
/// 3. rects already ≥ 90 % covered by existing redactions on the page are not added again.
extension PDFRedactor {
    /// Fraction of a candidate rect (sampled including its edges) that must already be redacted
    /// for it to count as a duplicate. 1: any uncovered sliver could expose part of a glyph.
    static let duplicateCoverage = 1.0

    /// Runs detection over every page and places redactions. Returns the report (also stored
    /// in `phase`), or nil when cancelled, when there is no document, or when the detector failed.
    @discardableResult
    func runDetection(using detector: any PIIDetecting) async -> PDFDetectionReport? {
        guard let doc = document else { return nil }
        beginDetection()
        var report = PDFDetectionReport()
        for pageIndex in 0..<doc.pageCount {
            if Task.isCancelled || document !== doc { return nil }
            guard let page = doc.page(at: pageIndex) else {
                report.skippedPages.append(pageIndex)
                continue
            }
            guard await detectPage(page, index: pageIndex, in: doc, detector: detector, report: &report) else { return nil }
        }
        guard !Task.isCancelled, document === doc else { return nil }
        finishDetection(report)
        return report
    }

    /// Returns false when the run must stop (cancelled, document replaced, detector failed).
    private func detectPage(
        _ page: PDFPage, index: Int, in doc: PDFDocument, detector: any PIIDetecting, report: inout PDFDetectionReport
    ) async -> Bool {
        let nativeText = page.string ?? ""
        let hasNative = !nativeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let readings = await ocrReadings(forPageAt: index)
        if Task.isCancelled || document !== doc { return false }
        let textReadings = readings.filter { !$0.combinedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        if readings.isEmpty {
            if hasNative {
                report.pagesNotPixelChecked.append(index)
            } else {
                report.skippedPages.append(index)
                return true
            }
        }
        if !hasNative && textReadings.isEmpty {
            report.pagesWithoutText.append(index)
            return true
        }

        var spansByKey: [String: DetectedSpan] = [:]
        var locatedKeys = Set<String>()
        var candidates: [CGRect] = []
        func record(_ span: DetectedSpan, expected: String, found: [CGRect]) {
            let key = Self.fold(expected)
            spansByKey[key] = spansByKey[key] ?? span
            if !found.isEmpty { locatedKeys.insert(key) }
            candidates += found
        }
        /// Every OCR reading's boxes for `text` (covers the pixels whatever the text layer says).
        func pixelRects(of text: String) -> [CGRect] {
            textReadings.flatMap { ocrSearchRects(needle: text, in: $0, on: page) }
        }

        if hasNative {
            let result = await detector.detect(nativeText)
            if Task.isCancelled || document !== doc { return false }
            guard case .success(let spans) = result else {
                failDetection(result, page: index)
                return false
            }
            for span in spans {
                let expected = expectedText(for: span, in: nativeText)
                let found = nativeRects(for: span, expected: expected, in: nativeText, on: page) + pixelRects(of: expected)
                record(span, expected: expected, found: found)
            }
        }

        // The detector (an ML model) is the expensive part: skip a reading whose text it has
        // already seen (same characters ignoring whitespace/case, e.g. a clean page whose OCR
        // matches its text layer). Spans found earlier are still located in every reading.
        var seenTexts: Set<String> = hasNative ? [Self.fold(nativeText)] : []
        for ocr in textReadings {
            let ocrText = ocr.combinedText
            guard seenTexts.insert(Self.fold(ocrText)).inserted else { continue }
            let normalized = OCRNormalizer.normalize(ocrText)
            let result = await detector.detect(normalized.text)
            if Task.isCancelled || document !== doc { return false }
            guard case .success(let spans) = result else {
                failDetection(result, page: index)
                return false
            }
            for span in spans {
                let (s, e) = OCRNormalizer.translateRange(
                    start: span.start, end: span.end, map: normalized.offsetMap, originalCount: ocrText.count
                )
                let translated = DetectedSpan(category: span.category, text: span.text, start: s, end: e, confidence: span.confidence)
                let expected = expectedText(for: translated, in: ocrText)
                var found = ocrRects(for: translated, expected: expected, in: ocr, on: page) + pixelRects(of: expected)
                if hasNative { found += nativeSearchRects(needle: expected, in: nativeText, on: page) }
                record(translated, expected: expected, found: found)
            }
        }

        report.detectedSpanCount += spansByKey.count
        report.unlocatedSpans += spansByKey
            .filter { !locatedKeys.contains($0.key) }
            .map { UnlocatedSpan(pageIndex: index, category: $0.value.category, text: $0.value.text) }
            .sorted { $0.text < $1.text }
        place(candidates, on: page, report: &report)
        return true
    }

    private func failDetection(_ result: Result<[DetectedSpan], Error>, page index: Int) {
        if case .failure(let err) = result {
            phase = .failed("Inference error on page \(index + 1): \(err.localizedDescription)")
        }
    }

    private func place(_ rects: [CGRect], on page: PDFPage, report: inout PDFDetectionReport) {
        // Largest first, so a smaller rect inside a larger one is recognised as a duplicate.
        let ordered = rects.sorted { $0.width * $0.height > $1.width * $1.height }
        for rect in ordered where rect.width > 0.5 && rect.height > 0.5 {
            if Self.coverage(of: rect, by: redactionRects(on: page)) >= Self.duplicateCoverage { continue }
            if addRedaction(rect: rect, on: page, source: .auto) != nil {
                report.placedRectCount += 1
            } else {
                report.failedAttachCount += 1
            }
        }
    }

    /// Approximate fraction of `rect` covered by the union of `others`: a 13×13 grid that
    /// includes the rect's edges and corners (others are grown by 0.25 pt so shared edges count).
    static func coverage(of rect: CGRect, by others: [CGRect]) -> Double {
        guard !others.isEmpty, rect.width > 0, rect.height > 0 else { return 0 }
        let grown = others.map { $0.insetBy(dx: -0.25, dy: -0.25) }
        let steps = 12
        var covered = 0
        for i in 0...steps {
            for j in 0...steps {
                let p = CGPoint(x: rect.minX + CGFloat(i) / CGFloat(steps) * rect.width,
                                y: rect.minY + CGFloat(j) / CGFloat(steps) * rect.height)
                if grown.contains(where: { $0.contains(p) }) { covered += 1 }
            }
        }
        return Double(covered) / Double((steps + 1) * (steps + 1))
    }

    // MARK: - OCR

    /// OCR of the pristine page, read twice: with language correction (better words) and
    /// without (identifiers are not "corrected"). Empty when rendering or both OCR runs failed.
    func ocrReadings(forPageAt index: Int) async -> [OCRPage] {
        guard let page = pristineDocument?.page(at: index) else { return [] }
        let scale = PDFPageRenderer.scale(for: page.bounds(for: .mediaBox).size)
        guard let cg = PDFPageRenderer.render(page, scale: scale) else { return [] }
        var readings: [OCRPage] = []
        for correction in [true, false] {
            if let reading = try? await OCREngine.recognize(cg, languageCorrection: correction) {
                readings.append(reading)
            }
        }
        // A page scanned sideways: also read it turned upright both ways (which way is "up"
        // is unknown), boxes mapped back to the page.
        let size = CGSize(width: cg.width, height: cg.height)
        if readings.contains(where: { $0.isMostlySideways(pixelSize: size) }) {
            for orientation: CGImagePropertyOrientation in [.left, .right] {
                for correction in [true, false] {
                    if let reading = try? await OCREngine.recognize(cg, orientation: orientation, languageCorrection: correction) {
                        readings.append(reading)
                    }
                }
            }
        }
        return readings
    }

    // MARK: - Locating span text

    /// The text a span claims to cover: the detector's own text, or the offset slice if empty.
    func expectedText(for span: DetectedSpan, in text: String) -> String {
        let claimed = span.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !claimed.isEmpty { return claimed }
        return Self.substring(of: text, start: span.start, end: span.end)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Lowercased, whitespace removed.
    static func fold(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
    }

    /// Whitespace- and case-insensitive equality.
    static func textMatches(_ a: String, _ b: String) -> Bool {
        let fa = fold(a)
        return !fa.isEmpty && fa == fold(b)
    }

    /// Case-insensitive pattern for `needle` that allows any whitespace between its characters.
    static func tolerantPattern(_ needle: String) -> NSRegularExpression? {
        let chars = needle.filter { !$0.isWhitespace }
        guard !chars.isEmpty else { return nil }
        let pattern = chars.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s*")
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    static func substring(of text: String, start: Int, end: Int) -> String? {
        guard start >= 0, end > start, end <= text.count else { return nil }
        let s = text.index(text.startIndex, offsetBy: start)
        let e = text.index(text.startIndex, offsetBy: end)
        return String(text[s..<e])
    }

    private func nsRange(start: Int, end: Int, in text: String) -> NSRange? {
        guard start >= 0, start <= text.count, end <= text.count, start <= end else { return nil }
        let s = text.index(text.startIndex, offsetBy: start)
        let e = text.index(text.startIndex, offsetBy: end)
        return NSRange(s..<e, in: text)
    }

    /// Native text: the offset selection if its text really is the span's text, else a search.
    private func nativeRects(for span: DetectedSpan, expected: String, in pageText: String, on page: PDFPage) -> [CGRect] {
        if span.end > span.start,
           let range = nsRange(start: span.start, end: span.end, in: pageText),
           let selection = page.selection(for: range),
           let selected = selection.string,
           Self.textMatches(selected, expected) {
            let rects = perLineRects(of: selection, on: page)
            if !rects.isEmpty { return rects }
        }
        return nativeSearchRects(needle: expected, in: pageText, on: page)
    }

    /// Every whitespace/case-tolerant occurrence of `needle` in the page's native text.
    private func nativeSearchRects(needle: String, in pageText: String, on page: PDFPage) -> [CGRect] {
        guard let regex = Self.tolerantPattern(needle) else { return [] }
        let matches = regex.matches(in: pageText, range: NSRange(pageText.startIndex..., in: pageText))
        return matches.flatMap { match -> [CGRect] in
            guard let selection = page.selection(for: match.range) else { return [] }
            return perLineRects(of: selection, on: page)
        }
    }

    private func perLineRects(of selection: PDFSelection, on page: PDFPage) -> [CGRect] {
        var rects: [CGRect] = []
        for line in selection.selectionsByLine() {
            for selPage in line.pages where selPage === page {
                let bounds = line.bounds(for: selPage)
                if bounds.width > 0.5 && bounds.height > 0.5 { rects.append(bounds) }
            }
        }
        return rects
    }

    /// OCR text: the offset boxes if the offset slice really is the span's text, else a search.
    private func ocrRects(for span: DetectedSpan, expected: String, in ocrPage: OCRPage, on page: PDFPage) -> [CGRect] {
        if let slice = Self.substring(of: ocrPage.combinedText, start: span.start, end: span.end),
           Self.textMatches(slice, expected) {
            let rects = ocrPage.normalizedBoxes(start: span.start, end: span.end).map { pageRect(fromNormalized: $0, on: page) }
            if !rects.isEmpty { return rects }
        }
        return ocrSearchRects(needle: expected, in: ocrPage, on: page)
    }

    /// Every whitespace/case-tolerant occurrence of `needle` in the OCR text, as page rects.
    private func ocrSearchRects(needle: String, in ocrPage: OCRPage, on page: PDFPage) -> [CGRect] {
        let text = ocrPage.combinedText
        guard let regex = Self.tolerantPattern(needle) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).flatMap { match -> [CGRect] in
            guard let r = Range(match.range, in: text) else { return [] }
            let s = text.distance(from: text.startIndex, to: r.lowerBound)
            let e = text.distance(from: text.startIndex, to: r.upperBound)
            return ocrPage.normalizedBoxes(start: s, end: e).map { pageRect(fromNormalized: $0, on: page) }
        }
    }

    /// Vision boxes are normalized with a bottom-left origin, like (normalized) page space.
    /// They hug the glyph row and can clip ascenders/descenders, so they are padded by a
    /// fraction of the line height.
    private func pageRect(fromNormalized norm: CGRect, on page: PDFPage) -> CGRect {
        let pageBounds = page.bounds(for: .mediaBox)
        let rect = CGRect(
            x: pageBounds.minX + norm.minX * pageBounds.width,
            y: pageBounds.minY + norm.minY * pageBounds.height,
            width: norm.width * pageBounds.width,
            height: norm.height * pageBounds.height
        )
        // Line thickness is the box's short side (text may run vertically on rotated pages).
        let thickness = min(rect.width, rect.height)
        let across = max(1, thickness * Self.ocrPaddingAcross)
        let along = max(1, thickness * Self.ocrPaddingAlong)
        let padded = rect.width >= rect.height
            ? rect.insetBy(dx: -along, dy: -across)
            : rect.insetBy(dx: -across, dy: -along)
        return padded.intersection(pageBounds)
    }

    /// Padding of OCR boxes, as a fraction of the line thickness: across the line
    /// (ascenders/descenders) and along it (first/last glyph).
    static let ocrPaddingAcross: CGFloat = 0.25
    static let ocrPaddingAlong: CGFloat = 0.1
}
