import Testing
import Foundation
import PDFKit
@testable import HideMyData

/// Honest state: what the status says must match what is on the page.
@MainActor
@Suite("PDF detection state")
struct PDFDetectionStateTests {

    @Test("Zero detections is reported as 'nothing found', not success")
    func zeroDetections() async throws {
        let (redactor, report) = await loadAndDetect(Fixture(name: "plain"), detector: StubDetector(needles: []))
        let r = try #require(report)
        #expect(r.detectedSpanCount == 0)
        #expect(r.placedRectCount == 0)
        #expect(!r.needsManualReview)
        #expect(redactor.redactionCount == 0)
        #expect(redactor.phase == .detected(r))
        #expect(redactor.statusText == "No personal data found")
    }

    @Test("A detected span that is not on the page is reported, not dropped")
    func unlocatedSpan() async throws {
        let detector = StubDetector()
        detector.phantomTexts = ["Zebediah Quux-Phantom 4242"]
        let (redactor, report) = await loadAndDetect(Fixture(name: "plain"), detector: detector)
        let r = try #require(report)
        #expect(r.detectedSpanCount == 6)
        #expect(r.placedRectCount >= 5)
        #expect(r.unlocatedSpans == [UnlocatedSpan(pageIndex: 0, category: "test", text: "Zebediah Quux-Phantom 4242")])
        #expect(r.needsManualReview)
        let summary = try #require(r.reviewSummary)
        #expect(summary.contains("could not be located"))
        #expect(summary.contains("page 1"))
        #expect(redactor.statusText.contains("redact manually"))
        #expect(redactor.redactionCount == r.placedRectCount)
    }

    @Test("Shifted offsets are not trusted; the span text is located instead")
    func shiftedOffsetsFallBackToTextSearch() async throws {
        let detector = StubDetector()
        detector.offsetShift = 4
        let fixture = Fixture(name: "plain")
        let (redactor, report) = await loadAndDetect(fixture, detector: detector)
        let r = try #require(report)
        #expect(r.unlocatedSpans.isEmpty)
        let page = try #require(redactor.document?.page(at: 0))
        let rects = redactor.redactionRects(on: page)
        #expect(!rects.isEmpty)
        // Every rect must sit on a real secret, never on the shifted (wrong) characters.
        var secretRects: [CGRect] = []
        for secret in Fixture.secrets {
            secretRects += expectedDisplayRects(of: secret, in: fixture)[0] ?? []
        }
        for rect in rects {
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let onSecret = secretRects.contains { $0.insetBy(dx: -4, dy: -4).contains(center) }
            #expect(onSecret, "rect \(rect) is not on a secret")
        }
        // And every secret is covered.
        for s in secretRects {
            #expect(PDFRedactor.coverage(of: s.insetBy(dx: 1, dy: 1), by: rects) == 1, "secret at \(s) not covered")
        }
    }

    @Test("Page without any text is reported as such")
    func blankPage() async throws {
        let url = temporaryOutputURL("blank")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeBlankPDF(to: url)
        let redactor = makeRedactor()
        #expect(redactor.loadPDF(from: url))
        let r = try #require(await redactor.runDetection(using: StubDetector()))
        #expect(r.pagesWithoutText == [0])
        #expect(r.skippedPages.isEmpty)
        #expect(r.detectedSpanCount == 0)
        #expect(!r.needsManualReview)
        #expect(r.notice == "Nothing readable on page 1 — check visually")
        #expect(redactor.statusText.hasPrefix("No personal data found"))
        #expect(redactor.statusText.contains("check visually"))
    }

    @Test("Detector failure is a failure, not a success")
    func detectorFailure() async throws {
        let detector = StubDetector()
        detector.failure = HMDError.message("boom")
        let (redactor, report) = await loadAndDetect(Fixture(name: "plain"), detector: detector)
        #expect(report == nil)
        guard case .failed(let message) = redactor.phase else {
            Issue.record("expected .failed, got \(redactor.phase)")
            return
        }
        #expect(message.contains("boom"))
    }

    @Test("Count reflects attached annotations through manual edits")
    func countsFollowPage() async throws {
        let (redactor, _) = await loadAndDetect(Fixture(name: "rot90"))
        let page = try #require(redactor.document?.page(at: 0))
        let attached = { page.annotations.filter { redactor.isRedaction($0) }.count }
        #expect(attached() == redactor.redactionCount)
        let ann = try #require(page.annotations.first { redactor.isRedaction($0) })
        redactor.removeRedaction(ann, on: page)
        #expect(attached() == redactor.redactionCount)
        redactor.clearRedactions()
        #expect(redactor.redactionCount == 0)
        #expect(page.annotations.isEmpty)
        #expect(redactor.phase == .loaded)
    }

    @Test("Switching style keeps every redaction attached")
    func restyle() async throws {
        let (redactor, report) = await loadAndDetect(Fixture(name: "owner256"))
        let count = try #require(report).placedRectCount
        redactor.redactionStyle = .blur
        let page = try #require(redactor.document?.page(at: 0))
        #expect(redactor.redactionCount == count)
        #expect(page.annotations.filter { $0 is BlurRedactionAnnotation }.count == count)
        #expect(!page.annotations.contains { $0 is BlackRedactionAnnotation })
    }

    @Test("Detection keeps manual redactions and replaces only its own")
    func manualRedactionsSurviveDetection() async throws {
        let redactor = makeRedactor()
        #expect(redactor.loadPDF(from: Fixture(name: "plain").url))
        let page = try #require(redactor.document?.page(at: 0))
        let manualRect = CGRect(x: 300, y: 300, width: 100, height: 50)
        let manual = try #require(redactor.addRedaction(rect: manualRect, on: page))

        let first = try #require(await redactor.runDetection(using: StubDetector()))
        #expect(page.annotations.contains { $0 === manual })
        #expect(redactor.isRedaction(manual))
        #expect(redactor.redactionRects(on: page, source: .manual).count == 1)
        #expect(redactor.redactionCount == first.placedRectCount + 1)

        // Running again replaces the automatic ones (no pile-up) and still keeps the manual one.
        let second = try #require(await redactor.runDetection(using: StubDetector()))
        #expect(second.placedRectCount == first.placedRectCount)
        #expect(redactor.redactionCount == second.placedRectCount + 1)
        #expect(page.annotations.contains { $0 === manual })

        // "Clear all" removes both kinds.
        redactor.clearRedactions()
        #expect(redactor.redactionCount == 0)
        #expect(page.annotations.isEmpty)
    }

    @Test("Saving with unlocated items keeps saying so after the save")
    func savedStatusKeepsReview() async throws {
        let detector = StubDetector()
        detector.phantomTexts = ["Zebediah Quux-Phantom 4242"]
        let (redactor, report) = await loadAndDetect(Fixture(name: "plain"), detector: detector)
        #expect(try #require(report).needsManualReview)
        let out = temporaryOutputURL("saved-review")
        defer { try? FileManager.default.removeItem(at: out) }
        #expect((try? redactor.export(to: out, options: ExportOptions()).get()) == out)
        #expect(redactor.phase == .saved(out))
        #expect(redactor.detectionReport?.needsManualReview == true)
        #expect(redactor.statusText.contains("redact manually"), "\(redactor.statusText)")
    }

    @Test("Report wording for every kind of gap")
    func reportWording() {
        var r = PDFDetectionReport()
        #expect(r.reviewSummary == nil)
        #expect(r.notice == nil)
        r.pagesNotPixelChecked = [2]
        #expect(r.needsManualReview)
        #expect(r.reviewSummary?.contains("page 3") == true)
        r = PDFDetectionReport()
        r.pagesWithoutText = [0, 4]
        #expect(!r.needsManualReview)
        #expect(r.notice == "Nothing readable on pages 1, 5 — check visually")
        r.skippedPages = [1]
        #expect(r.reviewSummary?.contains("could not be read (page 2)") == true)
    }

    @Test("Duplicate check never treats a partly uncovered rect as covered")
    func coverageIncludesEdges() {
        let big = CGRect(x: 0, y: 0, width: 100, height: 20)
        #expect(PDFRedactor.coverage(of: CGRect(x: 10, y: 2, width: 50, height: 10), by: [big]) == 1)
        // A 1-pt sliver sticking out on the right must count as not fully covered.
        #expect(PDFRedactor.coverage(of: CGRect(x: 50, y: 2, width: 51, height: 10), by: [big]) < 1)
        // Two touching rects together cover their union.
        let left = CGRect(x: 0, y: 0, width: 50, height: 20), right = CGRect(x: 50, y: 0, width: 50, height: 20)
        #expect(PDFRedactor.coverage(of: CGRect(x: 10, y: 5, width: 80, height: 10), by: [left, right]) == 1)
    }

    @Test("A refused addAnnotation is detected, not counted")
    func attachFailureIsDetected() throws {
        // The ORIGINAL permission-restricted document refuses annotations (PDFKit logs
        // "addAnnotation: failed" here on purpose); this is why the app works on a normalized copy.
        let raw = try #require(PDFDocument(url: Fixture(name: "owner256").url))
        let page = try #require(raw.page(at: 0))
        let ann = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 20, height: 20), forType: .square, withProperties: nil)
        #expect(!PDFRedactor.attach(ann, to: page))
    }

    @Test("A page outside the working document is refused, not counted")
    func foreignPageRefused() throws {
        let redactor = makeRedactor()
        #expect(redactor.loadPDF(from: Fixture(name: "plain").url))
        let other = try #require(PDFDocument(url: Fixture(name: "rot90").url)?.page(at: 0))
        #expect(redactor.addRedaction(rect: CGRect(x: 10, y: 10, width: 40, height: 20), on: other) == nil)
        #expect(redactor.redactionCount == 0)
        if case .failed = redactor.phase {} else { Issue.record("expected .failed, got \(redactor.phase)") }
    }

    private func writeBlankPDF(to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        let ctx = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        ctx.beginPage(mediaBox: &box)
        ctx.endPage()
        ctx.closePDF()
    }
}
