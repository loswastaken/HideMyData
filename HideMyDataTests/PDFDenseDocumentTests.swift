import Testing
import Foundation
import PDFKit
import CoreText
import AppKit
@testable import HideMyData

/// Dense, multi-font, multi-page document generated at test time (like macOS "Save as PDF"):
/// secrets on adjacent lines and several per line, so redactions overlap and abut.
@MainActor
@Suite("Dense generated document")
struct PDFDenseDocumentTests {
    static let secrets = ["Marguerite Fitzwilliam-Offenbach", "4539 1488 0343 6001", "m.fitzwilliam@example.org", "DE89 3704 0044"]
    static let fragments = ["Marguerite", "Fitzwilliam", "Offenbach", "4539", "1488 0343", "example.org", "DE89", "3704 0044"]

    static func makeDocument(pages: Int = 3) throws -> URL {
        let url = temporaryOutputURL("dense")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        let fonts = ["Times New Roman", "Georgia", "Menlo", "Avenir Next", "Baskerville"]
        for p in 1...pages {
            ctx.beginPDFPage(nil)
            let font = NSFont(name: fonts[p % fonts.count], size: 11 + CGFloat(p % 3)) ?? NSFont.systemFont(ofSize: 12)
            var body = "Statement page \(p): official office filing, efficient affluent fjord.\n\n"
            body += "Customer: Marguerite Fitzwilliam-Offenbach  Card: 4539 1488 0343 6001\n"
            body += "IBAN DE89 3704 0044  Holder Marguerite Fitzwilliam-Offenbach\n"
            body += "Mail m.fitzwilliam@example.org  Card 4539 1488 0343 6001\n"
            body += "Marguerite Fitzwilliam-Offenbach\n4539 1488 0343 6001\n"
            for i in 1...16 { body += "Line \(i): ordinary ledger text that should stay readable, amount \(i * p).00 USD.\n" }
            let attr = NSAttributedString(string: body, attributes: [.font: font, .foregroundColor: NSColor.black])
            let framesetter = CTFramesetterCreateWithAttributedString(attr)
            let path = CGPath(rect: CGRect(x: 54, y: 54, width: 504, height: 684), transform: nil)
            CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil), ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }

    @Test("Blur and black exports of a dense document hide every secret and keep the text", arguments: RedactionStyle.allCases)
    func denseExport(style: RedactionStyle) async throws {
        let source = try Self.makeDocument()
        defer { try? FileManager.default.removeItem(at: source) }
        let redactor = makeRedactor()
        redactor.redactionStyle = style
        #expect(redactor.loadPDF(from: source))
        let report = try #require(await redactor.runDetection(using: StubDetector(needles: Self.secrets)))
        #expect(!report.needsManualReview, "\(report)")
        #expect(report.placedRectCount >= 3 * 8)

        // Redactions really overlap or touch somewhere (that is the point of this document).
        let page = try #require(redactor.document?.page(at: 0))
        let groups = PDFPageRenderer.connectedGroups(redactor.redactionRects(on: page), tolerance: 1)
        #expect(groups.contains { $0.count > 1 })

        let out = temporaryOutputURL("dense-\(style.rawValue)")
        defer { try? FileManager.default.removeItem(at: out) }
        let result = redactor.export(to: out, options: ExportOptions())
        #expect((try? result.get()) == out, "\(result)")
        let output = try #require(PDFDocument(url: out))
        #expect(output.pageCount == 3)
        for i in 0..<output.pageCount {
            let outPage = try #require(output.page(at: i))
            let text = (outPage.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(text.isEmpty)
            let rendered = try #require(RenderedPage(outPage))
            let ocr = await recognizedText(in: rendered.image)
            let folded = ocr.lowercased().filter { !$0.isWhitespace }
            let leaked = Self.fragments.filter { folded.contains($0.lowercased().filter { !$0.isWhitespace }) }
            #expect(leaked.isEmpty, "\(style) page \(i + 1): OCR still reads \(leaked)")
            #expect(folded.contains("ordinaryledgertextthatshouldstayreadable"), "\(style) page \(i + 1): public text lost")
        }
    }

    @Test("Overlapping and touching regions are grouped; separate ones are not")
    func grouping() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 20)
        let b = CGRect(x: 50, y: 15, width: 100, height: 20)   // overlaps a
        let c = CGRect(x: 151, y: 15, width: 30, height: 20)   // touches b within tolerance
        let d = CGRect(x: 400, y: 400, width: 30, height: 20)  // separate
        let groups = PDFPageRenderer.connectedGroups([a, b, c, d], tolerance: 2)
        #expect(groups.count == 2)
        #expect(groups.contains { Set($0.map(\.minX)) == [0, 50, 151] })
        #expect(groups.contains { $0 == [d] })
    }
}
