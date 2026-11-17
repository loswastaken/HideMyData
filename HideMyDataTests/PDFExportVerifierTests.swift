import Testing
import Foundation
import PDFKit
@testable import HideMyData

@MainActor
@Suite("PDF export verification")
struct PDFExportVerifierTests {
    let letter = CGSize(width: 612, height: 792)

    private func secretRects(_ fixture: Fixture = Fixture(name: "plain")) -> [CGRect] {
        Fixture.secrets.flatMap { expectedDisplayRects(of: $0, in: fixture)[0] ?? [] }
    }

    @Test("A vector (un-rasterized) PDF fails: it still has text")
    func rejectsTextPage() {
        let problems = PDFExportVerifier.problems(
            inFileAt: Fixture(name: "plain").url,
            expected: PDFExportExpectation(pages: [.init(size: letter, baked: true, blackRects: [])])
        )
        #expect(problems.contains { $0.contains("extractable text") }, "\(problems)")
    }

    @Test("An un-redacted raster fails the black-pixel check")
    func rejectsUnredactedRaster() async throws {
        // Export plain.pdf with no redactions at all: a raster page with every secret visible.
        let redactor = makeRedactor()
        #expect(redactor.loadPDF(from: Fixture(name: "plain").url))
        let out = temporaryOutputURL("unredacted")
        defer { try? FileManager.default.removeItem(at: out) }
        #expect((try? redactor.export(to: out, options: ExportOptions()).get()) == out)

        let rects = secretRects()
        #expect(rects.count >= 5)
        let problems = PDFExportVerifier.problems(
            inFileAt: out,
            expected: PDFExportExpectation(pages: [.init(size: letter, baked: true, blackRects: rects)])
        )
        #expect(problems.count == rects.count, "\(problems)")
        #expect(problems.allSatisfy { $0.contains("black") })
    }

    @Test("A correctly redacted export passes")
    func acceptsRedacted() async throws {
        let (redactor, _) = await loadAndDetect(Fixture(name: "plain"))
        let out = temporaryOutputURL("good")
        defer { try? FileManager.default.removeItem(at: out) }
        #expect((try? redactor.export(to: out, options: ExportOptions()).get()) == out)
        let page = try #require(redactor.document?.page(at: 0))
        let problems = PDFExportVerifier.problems(
            inFileAt: out,
            expected: PDFExportExpectation(pages: [.init(size: letter, baked: true, blackRects: redactor.redactionRects(on: page))])
        )
        #expect(problems.isEmpty, "\(problems)")
    }

    @Test("Wrong page count, wrong size, annotations and unreadable files are reported")
    func structuralProblems() throws {
        let plain = Fixture(name: "plain").url
        let twoPages = PDFExportExpectation(pages: [
            .init(size: letter, baked: false, blackRects: []), .init(size: letter, baked: false, blackRects: [])
        ])
        #expect(PDFExportVerifier.problems(inFileAt: plain, expected: twoPages).contains { $0.contains("page count") })

        let wrongSize = PDFExportExpectation(pages: [.init(size: CGSize(width: 100, height: 100), baked: false, blackRects: [])])
        #expect(PDFExportVerifier.problems(inFileAt: plain, expected: wrongSize).contains { $0.contains("size") })

        let doc = try #require(PDFDocument(url: plain))
        let page = try #require(doc.page(at: 0))
        page.addAnnotation(PDFAnnotation(bounds: CGRect(x: 0, y: 0, width: 10, height: 10), forType: .square, withProperties: nil))
        let annotated = temporaryOutputURL("annotated")
        defer { try? FileManager.default.removeItem(at: annotated) }
        #expect(doc.write(to: annotated))
        let one = PDFExportExpectation(pages: [.init(size: letter, baked: false, blackRects: [])])
        #expect(PDFExportVerifier.problems(inFileAt: annotated, expected: one).contains { $0.contains("annotation") })

        let garbage = temporaryOutputURL("garbage")
        defer { try? FileManager.default.removeItem(at: garbage) }
        try Data("nope".utf8).write(to: garbage)
        #expect(!PDFExportVerifier.problems(inFileAt: garbage, expected: one).isEmpty)
    }

    @Test("Blur check: an unblurred region is rejected, a real blur export passes")
    func blurCheck() async throws {
        // Unredacted raster: the secret regions are still crisp text.
        let raw = makeRedactor()
        #expect(raw.loadPDF(from: Fixture(name: "plain").url))
        let unblurred = temporaryOutputURL("unblurred")
        defer { try? FileManager.default.removeItem(at: unblurred) }
        #expect((try? raw.export(to: unblurred, options: ExportOptions()).get()) == unblurred)
        let rects = secretRects()
        let problems = PDFExportVerifier.problems(
            inFileAt: unblurred,
            expected: PDFExportExpectation(pages: [.init(size: letter, baked: true, blackRects: [], blurRects: rects)])
        )
        #expect(problems.count == rects.count, "\(problems)")
        #expect(problems.allSatisfy { $0.contains("fine detail") })

        // A real blur export of the same page passes the same check.
        let (redactor, _) = await loadAndDetect(Fixture(name: "plain"), style: .blur)
        let blurred = temporaryOutputURL("blurred")
        defer { try? FileManager.default.removeItem(at: blurred) }
        #expect((try? redactor.export(to: blurred, options: ExportOptions()).get()) == blurred)
        let page = try #require(redactor.document?.page(at: 0))
        let ok = PDFExportVerifier.problems(
            inFileAt: blurred,
            expected: PDFExportExpectation(pages: [.init(size: letter, baked: true, blackRects: [], blurRects: redactor.redactionRects(on: page))])
        )
        #expect(ok.isEmpty, "\(ok)")
    }

    @Test("Blur over high-contrast edges and thin/tall regions still exports", arguments: [
        CGRect(x: 50, y: 397, width: 200, height: 5),     // thin, straddles the band's top edge
        CGRect(x: 300, y: 350, width: 20, height: 100),   // tall and narrow, crosses the edge
        CGRect(x: 100, y: 280, width: 300, height: 140),  // large, contains the whole band edge
        CGRect(x: 40, y: 640, width: 260, height: 30)     // over text
    ])
    func blurOverEdges(rect: CGRect) throws {
        let url = temporaryOutputURL("band")
        defer { try? FileManager.default.removeItem(at: url) }
        var box = CGRect(origin: .zero, size: letter)
        let ctx = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        ctx.beginPage(mediaBox: &box)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 300, width: 612, height: 100))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        for i in 0..<40 { ctx.fill(CGRect(x: 40 + CGFloat(i) * 6.5, y: 645, width: 3, height: 20)) }
        ctx.endPage()
        ctx.closePDF()

        let redactor = makeRedactor()
        redactor.redactionStyle = .blur
        #expect(redactor.loadPDF(from: url))
        let page = try #require(redactor.document?.page(at: 0))
        #expect(redactor.addRedaction(rect: rect, on: page) != nil)
        let out = temporaryOutputURL("band-out")
        defer { try? FileManager.default.removeItem(at: out) }
        let result = redactor.export(to: out, options: ExportOptions())
        #expect((try? result.get()) == out, "\(result)")
    }

    @Test("The editor's blur preview shows no fine detail either")
    func blurPreview() async throws {
        let (redactor, _) = await loadAndDetect(Fixture(name: "plain"), style: .blur)
        let page = try #require(redactor.document?.page(at: 0))
        // Render the working page WITH its annotations, as the editor shows it.
        let box = page.bounds(for: .mediaBox)
        let ctx = try #require(PDFPageRenderer.whiteContext(size: box.size, scale: 2))
        ctx.scaleBy(x: 2, y: 2)
        page.draw(with: .mediaBox, to: ctx)
        let image = try #require(ctx.makeImage())
        let bitmap = try #require(RGBABitmap(image))
        let rects = redactor.redactionRects(on: page)
        #expect(!rects.isEmpty)
        for rect in rects {
            let edges = bitmap.edgeFraction(in: rect.insetBy(dx: 1.75, dy: 1.75), scale: 2, step: PDFExportVerifier.blurEdgeStep)
            #expect(edges <= PDFExportVerifier.blurMaxEdgeFraction, "preview at \(rect) has detail \(edges)")
        }
        #expect(recognizedSecrets(in: await recognizedText(in: image)).isEmpty)
    }

    @Test("A blank verification render is reported as 'could not verify', not '0% black'")
    func blankRender() throws {
        let url = temporaryOutputURL("white")
        defer { try? FileManager.default.removeItem(at: url) }
        var box = CGRect(origin: .zero, size: letter)
        let ctx = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        ctx.beginPage(mediaBox: &box)
        ctx.endPage()
        ctx.closePDF()
        let problems = PDFExportVerifier.problems(
            inFileAt: url,
            expected: PDFExportExpectation(pages: [.init(size: letter, baked: true, blackRects: [CGRect(x: 10, y: 10, width: 50, height: 20)])])
        )
        #expect(problems.count == 1)
        #expect(problems.first?.contains("could not be verified") == true, "\(problems)")
    }

    @Test("Render scale is capped for huge pages")
    func renderScaleCap() {
        #expect(PDFPageRenderer.scale(for: CGSize(width: 612, height: 792)) == 2)
        let huge = CGSize(width: 14_400, height: 14_400)
        let s = PDFPageRenderer.scale(for: huge)
        #expect(huge.width * s <= PDFPageRenderer.maxPixelEdge)
        #expect(huge.width * s * huge.height * s <= PDFPageRenderer.maxPixelCount + 1)
        let wide = CGSize(width: 14_000, height: 60)
        #expect(wide.width * PDFPageRenderer.scale(for: wide) <= PDFPageRenderer.maxPixelEdge)
    }

    @Test("If the written file is bad, export fails and leaves nothing at the destination")
    func exportRefusesBadFile() async throws {
        let (redactor, _) = await loadAndDetect(Fixture(name: "plain"))
        let original = Fixture(name: "plain").url
        redactor.afterTemporaryWrite = { tmp in
            // Simulate a broken bake: swap in the unredacted original.
            try? FileManager.default.removeItem(at: tmp)
            try? FileManager.default.copyItem(at: original, to: tmp)
        }
        let out = temporaryOutputURL("refused")
        let result = redactor.export(to: out, options: ExportOptions())
        guard case .failure(.verificationFailed(let problems)) = result else {
            Issue.record("expected verification failure, got \(result)")
            return
        }
        #expect(!problems.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: out.path))
        guard case .failed(let message) = redactor.phase else {
            Issue.record("expected .failed phase, got \(redactor.phase)")
            return
        }
        #expect(message.contains("verification failed"))
    }

    @Test("Existing destination is replaced only by a verified file")
    func replacesExisting() async throws {
        let (redactor, _) = await loadAndDetect(Fixture(name: "rot270"))
        let out = temporaryOutputURL("replace")
        defer { try? FileManager.default.removeItem(at: out) }
        try Data("old contents".utf8).write(to: out)
        #expect((try? redactor.export(to: out, options: ExportOptions()).get()) == out)
        let doc = try #require(PDFDocument(url: out))
        #expect(doc.pageCount == 1)
        let text = doc.page(at: 0)?.string ?? ""
        #expect(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("A redaction detached behind the redactor's back blocks export")
    func inconsistentRedactions() async throws {
        let (redactor, _) = await loadAndDetect(Fixture(name: "plain"))
        let page = try #require(redactor.document?.page(at: 0))
        let ann = try #require(page.annotations.first)
        page.removeAnnotation(ann)
        let out = temporaryOutputURL("inconsistent")
        #expect(redactor.export(to: out, options: ExportOptions()) == .failure(.inconsistentRedactions))
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test("Metadata is removed by default and kept on request")
    func metadata() async throws {
        let (redactor, _) = await loadAndDetect(Fixture(name: "plain"))
        let stripped = temporaryOutputURL("stripped")
        let kept = temporaryOutputURL("kept")
        defer {
            try? FileManager.default.removeItem(at: stripped)
            try? FileManager.default.removeItem(at: kept)
        }
        #expect((try? redactor.export(to: stripped, options: ExportOptions(removeMetadata: true)).get()) == stripped)
        #expect((try? redactor.export(to: kept, options: ExportOptions(removeMetadata: false)).get()) == kept)
        let strippedAuthor = PDFDocument(url: stripped)?.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String
        let keptAuthor = PDFDocument(url: kept)?.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String
        #expect(strippedAuthor == nil)
        #expect(keptAuthor == "Johnathan Testerson")
        // Even with metadata kept, every page is rasterized.
        let keptText = PDFDocument(url: kept)?.page(at: 0)?.string ?? ""
        #expect(keptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
