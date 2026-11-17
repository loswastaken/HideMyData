import Testing
import Foundation
import PDFKit
@testable import HideMyData

/// Load → detect (stub) → export → reopen the output from disk and check it, including an
/// independent Vision OCR pass over the exported pixels.
@MainActor
@Suite("PDF end-to-end redaction")
struct PDFRedactionEndToEndTests {

    @Test("Black export hides every secret and keeps public text", arguments: Fixture.all)
    func blackExport(fixture: Fixture) async throws {
        let (redactor, report) = await loadAndDetect(fixture)
        let doc = try #require(redactor.document, "fixture \(fixture) did not load: \(redactor.phase)")
        let report2 = try #require(report)
        #expect(!report2.needsManualReview, "\(report2)")
        #expect(report2.placedRectCount > 0)
        #expect(redactor.redactionCount == report2.placedRectCount)

        let out = temporaryOutputURL(fixture.name)
        defer { try? FileManager.default.removeItem(at: out) }
        let result = redactor.export(to: out, options: ExportOptions(removeMetadata: true))
        #expect((try? result.get()) == out, "\(result)")
        #expect(redactor.phase == .saved(out))

        let output = try #require(PDFDocument(url: out))
        #expect(output.pageCount == doc.pageCount)
        try await assertRedacted(output, fixture: fixture, style: .blackRectangle)
    }

    @Test("Blur export destroys the secrets on every page size", arguments: [
        Fixture(name: "plain"), Fixture(name: "rot90")
    ] + Fixture.oddSizes.filter { $0.name != "big12000" } + [Fixture(name: "scan_with_footer", geometry: .none)])
    func blurExport(fixture: Fixture) async throws {
        let (redactor, report) = await loadAndDetect(fixture, style: .blur)
        let report2 = try #require(report)
        #expect(report2.placedRectCount > 0)
        let out = temporaryOutputURL("\(fixture.name)-blur")
        defer { try? FileManager.default.removeItem(at: out) }
        let result = redactor.export(to: out, options: ExportOptions())
        #expect((try? result.get()) == out, "\(result)")
        let output = try #require(PDFDocument(url: out))
        try await assertRedacted(output, fixture: fixture, style: .blur)
    }

    @Test("Redactions really attach on permission-restricted PDFs", arguments: Fixture.core.filter { $0.name.hasPrefix("owner") })
    func attachOnRestricted(fixture: Fixture) async throws {
        let (redactor, report) = await loadAndDetect(fixture)
        let doc = try #require(redactor.document)
        let report2 = try #require(report)
        #expect(report2.failedAttachCount == 0)
        var attached = 0
        for i in 0..<doc.pageCount {
            let page = try #require(doc.page(at: i))
            attached += page.annotations.filter { $0 is BlackRedactionAnnotation }.count
            for rect in redactor.redactionRects(on: page) {
                #expect(page.annotations.contains { $0.bounds == rect })
            }
        }
        #expect(attached == redactor.redactionCount)
        #expect(attached == report2.placedRectCount)
        #expect(attached > 0)

        // Manual add / remove work too.
        let page = try #require(doc.page(at: 0))
        let before = redactor.redactionCount
        let added = try #require(redactor.addRedaction(rect: CGRect(x: 10, y: 10, width: 40, height: 20), on: page))
        #expect(page.annotations.contains { $0 === added })
        #expect(redactor.redactionCount == before + 1)
        redactor.removeRedaction(added, on: page)
        #expect(!page.annotations.contains { $0 === added })
        #expect(redactor.redactionCount == before)
    }

    @Test("Loaded working copy is normalized and unrestricted", arguments: Fixture.core)
    func normalizedOnLoad(fixture: Fixture) throws {
        let redactor = makeRedactor(password: fixture.password)
        #expect(redactor.loadPDF(from: fixture.url))
        let doc = try #require(redactor.document)
        #expect(!doc.isEncrypted)
        #expect(!doc.isLocked)
        let original = try #require(PDFDocument(url: fixture.url))
        if original.isLocked, let pw = fixture.password { _ = original.unlock(withPassword: pw) }
        #expect(doc.pageCount == original.pageCount)
        for i in 0..<doc.pageCount {
            let page = try #require(doc.page(at: i))
            let source = try #require(original.page(at: i))
            #expect(PDFNormalizer.isNormalized(page))
            let size = displayedSize(of: source)
            #expect(abs(page.bounds(for: .mediaBox).width - size.width) < 0.5)
            #expect(abs(page.bounds(for: .mediaBox).height - size.height) < 0.5)
        }
    }

    @Test("Loading from in-memory data (recents path) normalizes too")
    func loadFromData() throws {
        let data = try Data(contentsOf: Fixture(name: "owner256rot90").url)
        let redactor = makeRedactor()
        #expect(redactor.loadPDF(data: data, originalURL: URL(fileURLWithPath: "/tmp/x.pdf")))
        let page = try #require(redactor.document?.page(at: 0))
        #expect(PDFNormalizer.isNormalized(page))
        #expect(!(redactor.document?.isEncrypted ?? true))
    }

    // MARK: - Output assertions

    private func assertRedacted(_ output: PDFDocument, fixture: Fixture, style: RedactionStyle) async throws {
        // No extractable text and no annotations anywhere.
        for i in 0..<output.pageCount {
            let page = try #require(output.page(at: i))
            let text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(text.isEmpty, "page \(i + 1) of \(fixture) still has text: \(text.prefix(80))")
            #expect(page.annotations.isEmpty)
            #expect(page.rotation == 0)
        }
        for secret in Fixture.secrets {
            #expect(output.findString(secret, withOptions: [.caseInsensitive]).isEmpty)
        }

        var renders: [Int: RenderedPage] = [:]
        func render(_ i: Int) throws -> RenderedPage {
            if let r = renders[i] { return r }
            let page = try #require(output.page(at: i))
            let r = try #require(RenderedPage(page))
            renders[i] = r
            return r
        }

        // Independent check: Vision OCR of the exported pixels finds no secret, but the header.
        var allText = ""
        for i in 0..<output.pageCount {
            allText += await recognizedText(in: try render(i).image) + "\n"
        }
        #expect(recognizedSecrets(in: allText).isEmpty, "\(fixture) \(style): OCR still reads \(recognizedSecrets(in: allText))")
        if fixture.hasHeader {
            #expect(containsHeader(allText), "\(fixture) \(style): OCR no longer reads the public header")
        }

        // Lying scans: the secrets' pixel locations come from Vision on the original page.
        if fixture.geometry == .none {
            guard style == .blackRectangle else { return }
            let rects = await ocrSecretRects(in: fixture)
            #expect(!rects.isEmpty, "Vision found no secret in the original \(fixture)")
            let rendered = try render(0)
            for rect in rects {
                let dark = rendered.darkFraction(in: rect.insetBy(dx: 0.5, dy: 0.5))
                #expect(dark > 0.97, "\(fixture) secret pixels at \(rect) only \(dark) dark")
            }
            return
        }

        // Pixel checks at the known secret locations (when the fixture's geometry is known).
        var checkedSecrets = 0
        for secret in Fixture.secrets {
            for (pageIndex, rects) in expectedDisplayRects(of: secret, in: fixture) {
                let rendered = try render(pageIndex)
                for rect in rects {
                    checkedSecrets += 1
                    let dark = rendered.darkFraction(in: rect.insetBy(dx: 1, dy: 1))
                    if style == .blackRectangle {
                        #expect(dark > 0.97, "\(fixture) p\(pageIndex + 1) '\(secret)' at \(rect) only \(dark) dark")
                    } else {
                        #expect(dark < 0.02, "\(fixture) p\(pageIndex + 1) '\(secret)' still has crisp glyphs (\(dark))")
                    }
                }
            }
        }
        #expect(checkedSecrets >= 1, "expected to locate the planted secrets in \(fixture)")

        // The public header must still be there: some ink, but not covered.
        guard fixture.hasHeader else { return }
        let headers = expectedDisplayRects(of: Fixture.publicHeader, in: fixture)
        #expect(!headers.isEmpty)
        for (pageIndex, rects) in headers {
            let rendered = try render(pageIndex)
            for rect in rects {
                let dark = rendered.darkFraction(in: rect)
                #expect(dark > 0.03 && dark < 0.6, "\(fixture) p\(pageIndex + 1) header dark fraction \(dark)")
            }
        }
    }
}
