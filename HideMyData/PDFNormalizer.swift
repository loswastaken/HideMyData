import Foundation
import PDFKit
import CoreGraphics

/// Re-distils an opened PDF into a sanitized working copy.
///
/// Every page is drawn exactly as it is displayed (crop box, `/Rotate` applied) into a fresh,
/// unencrypted PDF whose page media box is `(0, 0, displayed width, displayed height)`.
/// The result has rotation 0, a zero origin, media box == crop box, no permission
/// restrictions and no annotations of its own (existing annotation appearances are flattened
/// into the page content), so page space, display space and export pixel space all coincide.
enum PDFNormalizer {
    enum Failure: LocalizedError, Equatable {
        case locked
        case noPages
        case degeneratePage(index: Int)
        case renderFailed(index: Int)
        case unreadableResult

        var errorDescription: String? {
            switch self {
            case .locked: return "The PDF is password protected and could not be unlocked."
            case .noPages: return "The PDF has no pages."
            case .degeneratePage(let i): return "Page \(i + 1) has an invalid size."
            case .renderFailed(let i): return "Page \(i + 1) could not be prepared for redaction."
            case .unreadableResult: return "The PDF could not be prepared for redaction."
            }
        }
    }

    /// Smallest and largest page edge (in points) we accept. Quartz's own limit is 14 400 pt.
    static let minimumPageEdge: CGFloat = 1
    static let maximumPageEdge: CGFloat = 14_400

    /// The size a page occupies on screen: its crop box, with width/height swapped for 90/270.
    static func displayedSize(of page: PDFPage) -> CGSize {
        let crop = page.bounds(for: .cropBox)
        let rotation = ((page.rotation % 360) + 360) % 360
        return (rotation == 90 || rotation == 270)
            ? CGSize(width: crop.height, height: crop.width)
            : crop.size
    }

    static func normalize(_ source: PDFDocument) throws -> PDFDocument {
        try open(normalizedData(source), expectedPageCount: source.pageCount)
    }

    /// Opens normalized bytes and checks that every page really is normalized.
    static func open(_ data: Data, expectedPageCount: Int) throws -> PDFDocument {
        guard let result = PDFDocument(data: data),
              !result.isEncrypted, !result.isLocked,
              result.pageCount == expectedPageCount else {
            throw Failure.unreadableResult
        }
        for index in 0..<result.pageCount {
            guard let page = result.page(at: index), isNormalized(page) else {
                throw Failure.unreadableResult
            }
        }
        return result
    }

    /// The normalized PDF bytes (see type comment).
    static func normalizedData(_ source: PDFDocument) throws -> Data {
        guard !source.isLocked else { throw Failure.locked }
        guard source.pageCount > 0 else { throw Failure.noPages }

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            throw Failure.unreadableResult
        }

        for index in 0..<source.pageCount {
            guard let page = source.page(at: index) else {
                ctx.closePDF()
                throw Failure.renderFailed(index: index)
            }
            let size = displayedSize(of: page)
            guard size.width.isFinite, size.height.isFinite,
                  size.width >= minimumPageEdge, size.height >= minimumPageEdge,
                  size.width <= maximumPageEdge, size.height <= maximumPageEdge else {
                ctx.closePDF()
                throw Failure.degeneratePage(index: index)
            }
            var box = CGRect(origin: .zero, size: size)
            ctx.beginPage(mediaBox: &box)
            page.draw(with: .cropBox, to: ctx)
            ctx.endPage()
        }
        ctx.closePDF()
        return data as Data
    }

    /// True when page space == display space: no rotation, zero origin, crop == media.
    static func isNormalized(_ page: PDFPage) -> Bool {
        let media = page.bounds(for: .mediaBox)
        let crop = page.bounds(for: .cropBox)
        return page.rotation % 360 == 0 && media.origin == .zero && crop == media
    }
}
