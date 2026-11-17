import Foundation
import PDFKit
import CoreGraphics

/// What an exported file must look like. Built by `PDFRedactor` while it writes the export,
/// and checked against the file *as reopened from disk*.
struct PDFExportExpectation: Equatable {
    struct Page: Equatable {
        /// Expected media box size of the output page, in points.
        var size: CGSize
        /// True when the page was rasterized (must carry no extractable text).
        var baked: Bool
        /// Regions (output page space) that must render black.
        var blackRects: [CGRect]
        /// Regions (output page space) that must contain no fine detail (blur style).
        var blurRects: [CGRect] = []
    }

    var pages: [Page]
}

/// Independent post-write check of an exported PDF. Pure function of (file, expectation)
/// so it can be unit-tested against deliberately bad files.
enum PDFExportVerifier {
    /// A pixel counts as black when every channel is at or below this value.
    static let blackThreshold: UInt8 = 64
    /// Fraction of pixels inside a redaction rect that must be black.
    static let requiredBlackFraction = 0.995
    /// Points trimmed from each rect edge before sampling, to ignore resampling fringes.
    static let sampleInset: CGFloat = 0.75
    /// Blur check: a neighbouring-pixel luminance step larger than this counts as an edge…
    static let blurEdgeStep = 24
    /// …and at most this fraction of neighbour pairs inside a blur region may be edges.
    static let blurMaxEdgeFraction = 0.002

    /// Returns a list of human-readable problems. Empty means the file passed.
    static func problems(inFileAt url: URL, expected: PDFExportExpectation) -> [String] {
        guard let doc = PDFDocument(url: url) else {
            return ["the written file could not be reopened as a PDF"]
        }
        if doc.isLocked { return ["the written file is password protected"] }

        var problems: [String] = []
        if doc.pageCount != expected.pages.count {
            problems.append("page count is \(doc.pageCount), expected \(expected.pages.count)")
            return problems
        }

        for (index, want) in expected.pages.enumerated() {
            let label = "page \(index + 1)"
            guard let page = doc.page(at: index) else {
                problems.append("\(label) is missing")
                continue
            }
            if !page.annotations.isEmpty {
                problems.append("\(label) still carries \(page.annotations.count) annotation(s)")
            }
            let media = page.bounds(for: .mediaBox)
            if abs(media.width - want.size.width) > 0.5 || abs(media.height - want.size.height) > 0.5
                || page.rotation % 360 != 0 {
                problems.append("\(label) has size \(media.size) rotation \(page.rotation), expected \(want.size)")
                continue
            }
            if want.baked {
                let text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    problems.append("\(label) still contains extractable text")
                }
            }
            if !want.blackRects.isEmpty || !want.blurRects.isEmpty {
                problems.append(contentsOf: pixelProblems(page: page, expected: want, label: label))
            }
        }
        return problems
    }

    private static func pixelProblems(page: PDFPage, expected: PDFExportExpectation.Page, label: String) -> [String] {
        let media = page.bounds(for: .mediaBox)
        let scale = PDFPageRenderer.scale(for: media.size)
        guard let bitmap = render(page, scale: scale) else {
            return ["\(label) could not be verified: rendering failed"]
        }
        // A page with black redactions can never render pure white; if it does, the render
        // failed rather than the redaction. (A blur-only page can legitimately be near-white.)
        if !expected.blackRects.isEmpty, bitmap.isUniformWhite {
            return ["\(label) could not be verified: the verification render came back blank"]
        }
        var problems: [String] = []
        let pageRect = CGRect(origin: .zero, size: media.size)
        func sampleRect(_ rect: CGRect) -> CGRect? {
            let sample = rect.offsetBy(dx: -media.minX, dy: -media.minY)
                .insetBy(dx: sampleInset, dy: sampleInset)
                .intersection(pageRect)
            guard !sample.isNull, sample.width > 0, sample.height > 0 else { return nil }
            return sample
        }
        for rect in expected.blackRects {
            guard let sample = sampleRect(rect) else { continue }
            let fraction = bitmap.blackFraction(in: sample, scale: scale, threshold: blackThreshold)
            if fraction < requiredBlackFraction {
                let pct = Int((fraction * 100).rounded(.down))
                problems.append("\(label): redaction at \(rect.integral) is only \(pct)% black")
            }
        }
        for rect in expected.blurRects {
            // Extra inset: the mosaic+blur is clean inside, the region border is not.
            guard let sample = sampleRect(rect.insetBy(dx: 1, dy: 1)) else { continue }
            let edges = bitmap.edgeFraction(in: sample, scale: scale, step: blurEdgeStep)
            if edges > blurMaxEdgeFraction {
                problems.append("\(label): blurred region at \(rect.integral) still contains fine detail")
            }
        }
        return problems
    }

    /// Renders a page onto white, RGBA8, origin bottom-left in page space.
    static func render(_ page: PDFPage, scale: CGFloat) -> RGBABitmap? {
        guard let image = PDFPageRenderer.render(page, scale: scale) else { return nil }
        return RGBABitmap(image)
    }
}

/// Minimal RGBA8 bitmap. Row 0 is the TOP row (CGContext memory order).
struct RGBABitmap {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(width: Int, height: Int, bytes: [UInt8]) {
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    init?(_ image: CGImage) {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        self.init(width: w, height: h, bytes: Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: w * h * 4)))
    }

    var isUniformWhite: Bool {
        var i = 0
        while i < bytes.count {
            if bytes[i] < 250 || bytes[i + 1] < 250 || bytes[i + 2] < 250 { return false }
            i += 4
        }
        return true
    }

    /// Fraction of pixels in `rect` (page points, origin bottom-left) whose RGB are all ≤ threshold.
    func blackFraction(in rect: CGRect, scale: CGFloat, threshold: UInt8) -> Double {
        let (cols, rows) = pixelBounds(of: rect, scale: scale)
        guard !cols.isEmpty, !rows.isEmpty else { return 1 }
        var black = 0
        for row in rows {
            for col in cols {
                let i = (row * width + col) * 4
                if bytes[i] <= threshold && bytes[i + 1] <= threshold && bytes[i + 2] <= threshold { black += 1 }
            }
        }
        return Double(black) / Double(cols.count * rows.count)
    }

    /// Fraction of horizontally/vertically adjacent pixel pairs inside `rect` whose luminance
    /// differs by more than `step` — high for text and other fine detail, ~0 for a mosaic+blur.
    func edgeFraction(in rect: CGRect, scale: CGFloat, step: Int) -> Double {
        let (cols, rows) = pixelBounds(of: rect, scale: scale)
        guard cols.count > 1, rows.count > 1 else { return 0 }
        func luma(_ col: Int, _ row: Int) -> Int {
            let i = (row * width + col) * 4
            return (Int(bytes[i]) * 299 + Int(bytes[i + 1]) * 587 + Int(bytes[i + 2]) * 114) / 1000
        }
        var edges = 0, pairs = 0
        for row in rows {
            for col in cols {
                let l = luma(col, row)
                if col + 1 < cols.upperBound {
                    pairs += 1
                    if abs(luma(col + 1, row) - l) > step { edges += 1 }
                }
                if row + 1 < rows.upperBound {
                    pairs += 1
                    if abs(luma(col, row + 1) - l) > step { edges += 1 }
                }
            }
        }
        return pairs == 0 ? 0 : Double(edges) / Double(pairs)
    }

    /// Pixel columns and memory rows covered by a page-space rect.
    func pixelBounds(of rect: CGRect, scale: CGFloat) -> (cols: Range<Int>, rows: Range<Int>) {
        let x0 = max(0, Int((rect.minX * scale).rounded(.up)))
        let x1 = min(width, Int((rect.maxX * scale).rounded(.down)))
        // Flip: page y grows upward, memory rows grow downward.
        let y0 = max(0, height - Int((rect.maxY * scale).rounded(.down)))
        let y1 = min(height, height - Int((rect.minY * scale).rounded(.up)))
        return (x0..<max(x0, x1), y0..<max(y0, y1))
    }
}
