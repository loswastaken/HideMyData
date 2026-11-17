import Foundation
import PDFKit
import AppKit
internal import UniformTypeIdentifiers

enum RedactionStyle: String, CaseIterable, Identifiable {
    case blackRectangle
    case blur

    var id: Self { self }

    var displayName: String {
        switch self {
        case .blackRectangle: return "Black"
        case .blur: return "Blur"
        }
    }
}

enum EditingMode: String, CaseIterable, Identifiable {
    case view
    case add
    case remove

    var id: Self { self }

    var displayName: String {
        switch self {
        case .view: return "View"
        case .add: return "Add"
        case .remove: return "Remove"
        }
    }

    var systemImage: String {
        switch self {
        case .view: return "eye"
        case .add: return "plus.square"
        case .remove: return "minus.square"
        }
    }
}

enum PDFExportError: LocalizedError, Equatable {
    case noDocument
    case busy
    case inconsistentRedactions
    case renderFailed(page: Int)
    case writeFailed
    case verificationFailed([String])
    case moveFailed(String)

    var errorDescription: String? {
        switch self {
        case .noDocument: return "No document to export"
        case .busy: return "Wait for detection to finish before saving"
        case .inconsistentRedactions: return "Export refused: a redaction is no longer attached to its page"
        case .renderFailed(let page): return "Export failed: page \(page + 1) could not be rendered"
        case .writeFailed: return "Could not write redacted PDF"
        case .verificationFailed(let problems):
            return "Export refused — verification failed: " + problems.prefix(3).joined(separator: "; ")
        case .moveFailed(let reason): return "Could not save the verified PDF: \(reason)"
        }
    }
}

@Observable
@MainActor
final class PDFRedactor {
    enum Phase: Equatable {
        case empty
        case loaded
        case detecting
        case detected(PDFDetectionReport)
        case saved(URL)
        case failed(String)
    }

    enum RedactionSource { case auto, manual }

    struct TrackedRedaction {
        let page: PDFPage
        let annotation: PDFAnnotation
        let source: RedactionSource
    }

    var phase: Phase = .empty
    /// The sanitized working copy (see `PDFNormalizer`). Redaction annotations live here.
    var document: PDFDocument?
    var sourceURL: URL?
    var editingMode: EditingMode = .view
    var redactionStyle: RedactionStyle = .blackRectangle {
        didSet { if oldValue != redactionStyle { restyleAllAnnotations() } }
    }
    /// Result of the last detection run on this document; survives manual edits and saves so
    /// the status can keep saying what still needs manual review.
    private(set) var detectionReport: PDFDetectionReport?

    @ObservationIgnored var passwordProvider: PDFPasswordProvider
    /// Upper bound on password prompts per open, so a misbehaving provider cannot loop forever.
    @ObservationIgnored var maxPasswordAttempts = 20
    /// Test seam: called with the temporary export file after it is written and before it is
    /// verified (tests use it to corrupt the file and prove verification stops the save).
    @ObservationIgnored var afterTemporaryWrite: ((URL) -> Void)?

    /// Never-annotated twin of `document`, used for all rendering (OCR, blur preview, export),
    /// so redaction annotations never have to be detached and re-attached.
    @ObservationIgnored var pristineDocument: PDFDocument?
    @ObservationIgnored private var sourceAttributes: [AnyHashable: Any] = [:]

    private(set) var redactions: [TrackedRedaction] = []
    /// Sharp renders of pristine pages (for the blur preview), keyed by working page.
    private let renderCache: NSCache<PDFPage, CGImage> = {
        let cache = NSCache<PDFPage, CGImage>()
        cache.countLimit = 4
        return cache
    }()
    @ObservationIgnored private var detectionTask: Task<Void, Never>?

    init(passwordProvider: @escaping PDFPasswordProvider = { name, failed in
        PDFPasswordPrompt.ask(documentName: name, previousAttemptFailed: failed)
    }) {
        self.passwordProvider = passwordProvider
    }

    var statusText: String {
        let count = "\(redactionCount) redaction\(redactionCount == 1 ? "" : "s")"
        switch phase {
        case .empty: return "No document"
        case .loaded:
            return redactions.isEmpty ? "Loaded" : count
        case .detecting: return "Detecting PII…"
        case .detected(let report):
            if let review = report.reviewSummary { return "\(count); \(review)" }
            let base = redactionCount == 0 ? (report.detectedSpanCount == 0 ? "No personal data found" : "No redactions") : count
            return report.notice.map { "\(base); \($0)" } ?? base
        case .saved(let url):
            if let review = detectionReport?.reviewSummary { return "Saved → \(url.lastPathComponent); \(review)" }
            return "Saved → \(url.lastPathComponent)"
        case .failed(let m): return "Failed: \(m)"
        }
    }

    var hasRedactions: Bool { !redactions.isEmpty }
    var canDetect: Bool { document != nil && phase != .detecting }
    /// Number of redactions confirmed attached to their pages (only attached ones are tracked).
    var redactionCount: Int { redactions.count }

    /// Tracked redaction bounds for a page (page space), optionally filtered by source.
    func redactionRects(on page: PDFPage, source: RedactionSource? = nil) -> [CGRect] {
        redactions.filter { $0.page === page && (source == nil || $0.source == source) }.map { $0.annotation.bounds }
    }

    // MARK: - Open

    @discardableResult
    func openPDF() -> Bool {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return loadPDF(from: url)
    }

    @discardableResult
    func loadPDF(from url: URL) -> Bool {
        guard let doc = PDFDocument(url: url) else {
            phase = .failed("Could not open PDF at \(url.lastPathComponent)")
            return false
        }
        return ingest(doc, name: url.lastPathComponent, sourceURL: url)
    }

    /// Load a PDF whose bytes are already in memory. Used by the recents flow so the
    /// security-scoped resource can be released as soon as the file is read, while
    /// `sourceURL` still points at the original location for save-name suggestions.
    @discardableResult
    func loadPDF(data: Data, originalURL: URL) -> Bool {
        guard let doc = PDFDocument(data: data) else {
            phase = .failed("Could not open PDF at \(originalURL.lastPathComponent)")
            return false
        }
        return ingest(doc, name: originalURL.lastPathComponent, sourceURL: originalURL)
    }

    /// Unlock (if needed) and normalize. On failure the previous document stays open and
    /// `phase` explains why; a locked or unreadable file never becomes a blank document.
    private func ingest(_ source: PDFDocument, name: String, sourceURL: URL) -> Bool {
        guard unlockIfNeeded(source, name: name) else {
            phase = .failed("Password required to open \(name)")
            return false
        }
        let working: PDFDocument
        let pristine: PDFDocument
        do {
            let data = try PDFNormalizer.normalizedData(source)
            working = try PDFNormalizer.open(data, expectedPageCount: source.pageCount)
            pristine = try PDFNormalizer.open(data, expectedPageCount: source.pageCount)
        } catch {
            phase = .failed("Could not open \(name): \(error.localizedDescription)")
            return false
        }
        cancelDetection()
        removeRedactions { _ in true }
        renderCache.removeAllObjects()
        sourceAttributes = source.documentAttributes ?? [:]
        pristineDocument = pristine
        document = working
        detectionReport = nil
        self.sourceURL = sourceURL
        phase = .loaded
        return true
    }

    private func unlockIfNeeded(_ doc: PDFDocument, name: String) -> Bool {
        guard doc.isLocked else { return true }
        if doc.unlock(withPassword: ""), !doc.isLocked { return true }
        var previousFailed = false
        for _ in 0..<maxPasswordAttempts {
            guard let password = passwordProvider(name, previousFailed) else { return false }
            if doc.unlock(withPassword: password), !doc.isLocked { return true }
            previousFailed = true
        }
        return false
    }

    // MARK: - Save / export

    func save() {
        guard document != nil else { return }
        if let report = detectionReport, report.needsManualReview, !confirmSaveDespiteReview(report) { return }
        let panel = NSSavePanel()
        let exportAccessory = ExportOptionsAccessoryView()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedSaveName()
        panel.accessoryView = exportAccessory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        export(to: url, options: exportAccessory.options)
    }

    /// Asks before saving a document in which detection could not redact everything.
    /// Cancel is the default button.
    private func confirmSaveDespiteReview(_ report: PDFDetectionReport) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Some detected personal data may not be redacted"
        alert.informativeText = (report.reviewSummary ?? "") + ".\n\nAdd redactions for these items manually before saving, or save anyway."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Save Anyway")
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// Rasterizes the redacted document, writes it to a temporary file, reopens and verifies
    /// that file, and only then moves it to `url`. Sets `phase` to `.saved` or `.failed`.
    @discardableResult
    func export(to url: URL, options: ExportOptions) -> Result<URL, PDFExportError> {
        let result = buildVerifiedExport(to: url, options: options)
        switch result {
        case .success(let out): phase = .saved(out)
        case .failure(let error): phase = .failed(error.localizedDescription)
        }
        return result
    }

    private func buildVerifiedExport(to url: URL, options: ExportOptions) -> Result<URL, PDFExportError> {
        guard let doc = document, let pristine = pristineDocument else { return .failure(.noDocument) }
        if phase == .detecting { return .failure(.busy) }

        // Every tracked redaction must still be on its page; otherwise the view and the
        // export would disagree.
        for item in redactions where !item.page.annotations.contains(where: { $0 === item.annotation }) {
            return .failure(.inconsistentRedactions)
        }

        var expectation = PDFExportExpectation(pages: [])
        let writer = ImagePDFWriter()
        for pageIndex in 0..<doc.pageCount {
            guard let page = doc.page(at: pageIndex), let clean = pristine.page(at: pageIndex) else {
                return .failure(.renderFailed(page: pageIndex))
            }
            let rects = redactionRects(on: page)
            let size = page.bounds(for: .mediaBox).size

            // Every page is rasterized, including pages without redactions and with
            // "Remove metadata" off: a vector copy would still carry content the user
            // cannot see (text clipped away by the original crop box, white text,
            // hidden layers), which detection never looked at.
            let added = autoreleasepool { () -> Bool in
                guard let baked = bakedImage(clean, rects: rects, style: redactionStyle) else { return false }
                return writer.addPage(baked, size: size)
            }
            guard added else { return .failure(.renderFailed(page: pageIndex)) }
            let isBlack = redactionStyle == .blackRectangle
            expectation.pages.append(.init(size: size, baked: true, blackRects: isBlack ? rects : [], blurRects: isBlack ? [] : rects))
        }
        guard let newDoc = writer.finish() else { return .failure(.writeFailed) }
        newDoc.documentAttributes = options.removeMetadata ? [:] : sourceAttributes

        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("HideMyData-export-\(UUID().uuidString).pdf")
        defer { try? fm.removeItem(at: tmp) }
        guard newDoc.write(to: tmp) else { return .failure(.writeFailed) }
        afterTemporaryWrite?(tmp)

        let problems = PDFExportVerifier.problems(inFileAt: tmp, expected: expectation)
        guard problems.isEmpty else { return .failure(.verificationFailed(problems)) }

        do {
            try Self.moveVerifiedFile(tmp, to: url)
        } catch {
            return .failure(.moveFailed(error.localizedDescription))
        }
        return .success(url)
    }

    /// Moves the verified temp file into place, replacing an existing file, and checks that
    /// the bytes at the destination are exactly the verified bytes.
    private static func moveVerifiedFile(_ tmp: URL, to url: URL) throws {
        let fm = FileManager.default
        let verified = try Data(contentsOf: tmp)
        if fm.fileExists(atPath: url.path) {
            do {
                _ = try fm.replaceItemAt(url, withItemAt: tmp)
            } catch {
                // replaceItemAt can be refused inside the sandbox; the destination itself
                // is writable (user-selected), so overwrite it in place.
                try verified.write(to: url)
            }
        } else {
            do {
                try fm.moveItem(at: tmp, to: url)
            } catch {
                try verified.write(to: url)
            }
        }
        guard (try? Data(contentsOf: url)) == verified else {
            throw HMDError.message("the file on disk does not match the verified export")
        }
    }

    // MARK: - Detection entry points (the pipeline is in PDFRedactor+Detection.swift)

    func detectAndRedact(using detector: any PIIDetecting) {
        cancelDetection()
        detectionTask = Task { [weak self] in
            await self?.runDetection(using: detector)
        }
    }

    func cancelDetection() {
        detectionTask?.cancel()
        detectionTask = nil
    }

    func beginDetection() {
        // Detection replaces only its own earlier results; manual redactions stay.
        removeRedactions { $0.source == .auto }
        detectionReport = nil
        phase = .detecting
    }

    func finishDetection(_ report: PDFDetectionReport) {
        refreshAllBlurPreviews()
        detectionReport = report
        phase = .detected(report)
    }

    // MARK: - Annotations

    /// Adds a redaction and returns it, or nil when PDFKit did not actually attach it to the
    /// page (nothing is tracked or counted in that case).
    @discardableResult
    func addRedaction(rect: CGRect, on page: PDFPage, source: RedactionSource = .manual) -> PDFAnnotation? {
        // Only pages of the working document are exported; anything else would be counted
        // but never burned in.
        guard pageNumber(of: page) != nil else {
            if source == .manual { phase = .failed("Could not add the redaction to \(pageLabel(of: page))") }
            return nil
        }
        let ann = makeAnnotation(bounds: rect.insetBy(dx: -1, dy: -1), on: page)
        guard Self.attach(ann, to: page) else {
            if source == .manual {
                phase = .failed("Could not add the redaction to \(pageLabel(of: page))")
            }
            return nil
        }
        redactions.append(TrackedRedaction(page: page, annotation: ann, source: source))
        // During detection the previews are computed once at the end (finishDetection).
        if phase != .detecting { refreshBlurPreviews(on: page) }
        noteManualEdit()
        return ann
    }

    func removeRedaction(_ ann: PDFAnnotation, on page: PDFPage) {
        page.removeAnnotation(ann)
        if page.annotations.contains(where: { $0 === ann }) {
            // Still visible and still going to be baked: keep tracking it, and say so.
            phase = .failed("Could not remove the redaction on \(pageLabel(of: page))")
            return
        }
        redactions.removeAll { $0.annotation === ann }
        refreshBlurPreviews(on: page)
        noteManualEdit()
    }

    func isRedaction(_ ann: PDFAnnotation) -> Bool {
        redactions.contains { $0.annotation === ann }
    }

    /// "Clear all redactions": removes manual and automatic ones.
    func clearRedactions() {
        cancelDetection()
        let leftOver = removeRedactions { _ in true }
        guard document != nil else { return }
        detectionReport = nil
        phase = leftOver == 0 ? .loaded : .failed("Some redactions could not be removed")
    }

    /// Removes matching redactions; returns how many could not be removed (they stay tracked).
    @discardableResult
    private func removeRedactions(where shouldRemove: (TrackedRedaction) -> Bool) -> Int {
        var kept: [TrackedRedaction] = []
        var stuck = 0
        for item in redactions {
            guard shouldRemove(item) else { kept.append(item); continue }
            item.page.removeAnnotation(item.annotation)
            if item.page.annotations.contains(where: { $0 === item.annotation }) {
                kept.append(item)
                stuck += 1
            }
        }
        redactions = kept
        return stuck
    }

    /// A manual edit invalidates a saved/failed status but keeps a detection report visible.
    private func noteManualEdit() {
        switch phase {
        case .saved, .failed: phase = detectionReport.map { .detected($0) } ?? .loaded
        default: break
        }
    }

    private func makeAnnotation(bounds: CGRect, on page: PDFPage) -> PDFAnnotation {
        switch redactionStyle {
        case .blackRectangle:
            let blackAnn = BlackRedactionAnnotation(bounds: bounds, forType: .square, withProperties: nil)
            blackAnn.border = nil
            return blackAnn
        case .blur:
            // Its image is filled in by refreshBlurPreviews once it is attached and grouped.
            let blurAnn = BlurRedactionAnnotation(bounds: bounds, forType: .square, withProperties: nil)
            blurAnn.border = nil
            return blurAnn
        }
    }

    /// Adds the annotation and reports whether PDFKit really attached it (it silently refuses
    /// on permission-restricted documents).
    static func attach(_ ann: PDFAnnotation, to page: PDFPage) -> Bool {
        page.addAnnotation(ann)
        return page.annotations.contains { $0 === ann }
    }

    /// 1-based page number in the working document, or nil for a page that isn't in it.
    func pageNumber(of page: PDFPage) -> Int? {
        guard let doc = document else { return nil }
        let index = doc.index(for: page)
        return index == NSNotFound ? nil : index + 1
    }

    private func pageLabel(of page: PDFPage) -> String {
        pageNumber(of: page).map { "page \($0)" } ?? "a page outside the open document"
    }

    /// Swaps every annotation for one of the new style. The new one is attached before the old
    /// one is removed, so a failure can never leave an area unredacted.
    private func restyleAllAnnotations() {
        var updated: [TrackedRedaction] = []
        var failures = 0
        for item in redactions {
            let replacement = makeAnnotation(bounds: item.annotation.bounds, on: item.page)
            if Self.attach(replacement, to: item.page) {
                item.page.removeAnnotation(item.annotation)
                if item.page.annotations.contains(where: { $0 === item.annotation }) { updated.append(item) }
                updated.append(TrackedRedaction(page: item.page, annotation: replacement, source: item.source))
            } else {
                failures += 1
                updated.append(item)
            }
        }
        redactions = updated
        refreshAllBlurPreviews()
        if failures > 0 {
            phase = .failed("\(failures) redaction(s) could not be restyled; they are kept and will still be applied")
        }
    }

    // MARK: - Rendering

    /// The pristine twin of a working page.
    func pristinePage(for page: PDFPage) -> PDFPage? {
        guard let number = pageNumber(of: page) else { return nil }
        return pristineDocument?.page(at: number - 1)
    }

    /// Pixel region the bake obscures for an annotation (bounds + 2 px), at `scale`.
    static func bakeRegion(for bounds: CGRect, scale: CGFloat) -> CGRect {
        CGRect(x: bounds.minX * scale, y: bounds.minY * scale, width: bounds.width * scale, height: bounds.height * scale)
            .insetBy(dx: -2, dy: -2)
    }

    private func refreshAllBlurPreviews() {
        var pages: [PDFPage] = []
        for item in redactions where !pages.contains(where: { $0 === item.page }) { pages.append(item.page) }
        for page in pages { refreshBlurPreviews(on: page) }
    }

    /// Gives every blur annotation on the page the same group image the export bake will use
    /// (overlapping/touching redactions share one mosaic, so the editor shows no seams either).
    private func refreshBlurPreviews(on page: PDFPage) {
        guard redactionStyle == .blur, let clean = pristinePage(for: page) else { return }
        let items = redactions.filter { $0.page === page }
        guard !items.isEmpty else { return }
        let scale = PDFPageRenderer.scale(for: clean.bounds(for: .mediaBox).size)
        let sharp: CGImage
        if let cached = renderCache.object(forKey: page) {
            sharp = cached
        } else {
            guard let rendered = PDFPageRenderer.render(clean, scale: scale) else { return }
            renderCache.setObject(rendered, forKey: page)
            sharp = rendered
        }
        let imageBounds = CGRect(x: 0, y: 0, width: sharp.width, height: sharp.height)
        let regions = items.map { Self.bakeRegion(for: $0.annotation.bounds, scale: scale) }
        guard let groups = PDFPageRenderer.obscuredGroups(regions, in: sharp) else { return }
        for (item, region) in zip(items, regions) {
            guard let ann = item.annotation as? BlurRedactionAnnotation else { continue }
            let key = region.integral.intersection(imageBounds)
            guard let group = groups.first(where: { $0.regions.contains(key) }) else { continue }
            ann.blurredPageImage = group.image
            ann.pageMediaBoxRect = CGRect(x: group.frame.minX / scale, y: group.frame.minY / scale,
                                          width: group.frame.width / scale, height: group.frame.height / scale)
            ann.bounds = ann.bounds  // re-set so PDFKit redraws the annotation
        }
    }

    // MARK: - True (rasterized) bake

    /// Rasterizes a pristine (normalized, unannotated) page and burns the rects in.
    private func bakedImage(_ page: PDFPage, rects: [CGRect], style: RedactionStyle) -> CGImage? {
        let pageBounds = page.bounds(for: .mediaBox)
        let scale = PDFPageRenderer.scale(for: pageBounds.size)
        guard PDFNormalizer.isNormalized(page),
              let ctx = PDFPageRenderer.whiteContext(size: pageBounds.size, scale: scale) else { return nil }
        // Pixel dimensions are rounded, so scale x and y separately to fill the bitmap exactly.
        let sx = CGFloat(ctx.width) / pageBounds.width
        let sy = CGFloat(ctx.height) / pageBounds.height

        ctx.saveGState()
        ctx.scaleBy(x: sx, y: sy)
        page.draw(with: .mediaBox, to: ctx)
        ctx.restoreGState()

        let pixelRects: [CGRect] = rects.map { r in
            CGRect(x: r.minX * sx, y: r.minY * sy, width: r.width * sx, height: r.height * sy)
                .insetBy(dx: -2, dy: -2)
        }

        switch style {
        case .blackRectangle:
            ctx.setFillColor(NSColor.black.cgColor)
            for r in pixelRects { ctx.fill(r) }

        case .blur:
            guard let sharpCG = ctx.makeImage(),
                  PDFPageRenderer.obscure(pixelRects, in: ctx, from: sharpCG) else { return nil }
        }
        return ctx.makeImage()
    }

    private func suggestedSaveName() -> String {
        let base = sourceURL?.deletingPathExtension().lastPathComponent ?? "document"
        return "\(base)-redacted.pdf"
    }
}
