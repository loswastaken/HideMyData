import Foundation
import PDFKit
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
internal import UniformTypeIdentifiers

/// Shared page rasterization for OCR, the blur preview, the export bake and export verification.
/// Every render goes through `scale(for:)`, so huge pages never allocate unbounded bitmaps.
enum PDFPageRenderer {
    /// Preferred render scale (points → pixels): 144 dpi.
    static let preferredScale: CGFloat = 2
    /// Longest bitmap edge we allow, in pixels.
    static let maxPixelEdge: CGFloat = 10_000
    /// Largest bitmap we allow, in pixels (≈ 100 MB as RGBA8).
    static let maxPixelCount: CGFloat = 25_000_000

    /// Render scale for a page of `size` points: `preferredScale`, reduced for very large pages.
    static func scale(for size: CGSize) -> CGFloat {
        guard size.width > 0, size.height > 0 else { return preferredScale }
        let byEdge = maxPixelEdge / max(size.width, size.height)
        let byArea = (maxPixelCount / (size.width * size.height)).squareRoot()
        return min(preferredScale, byEdge, byArea)
    }

    /// A white RGBA8 bitmap context for `size` points at `scale`, not yet scaled.
    static func whiteContext(size: CGSize, scale: CGFloat) -> CGContext? {
        let pixelWidth = Int((size.width * scale).rounded())
        let pixelHeight = Int((size.height * scale).rounded())
        guard pixelWidth > 0, pixelHeight > 0,
              let ctx = CGContext(
                data: nil, width: pixelWidth, height: pixelHeight,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        return ctx
    }

    /// Renders a page (media box) onto white at `scale`. Pixel = page point × scale.
    static func render(_ page: PDFPage, scale: CGFloat) -> CGImage? {
        let box = page.bounds(for: .mediaBox)
        guard let ctx = whiteContext(size: box.size, scale: scale) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }

    // MARK: - Information-destroying blur

    /// Mosaic cell edge (pixels) for a region: at least half the region's shorter side, so the
    /// text height is covered by ≤ 2 cells regardless of page size.
    static func mosaicCell(for region: CGRect) -> CGFloat {
        max(4, (min(region.width, region.height) / 2).rounded(.up))
    }

    /// Returns an image of exactly `region` (pixel coordinates of `sharp`, origin bottom-left)
    /// in which the content is first reduced to a coarse mosaic (cell edge `cell`, default
    /// `mosaicCell(for: region)`) and then blurred.
    static func obscuredPatch(of sharp: CGImage, region: CGRect, cell: CGFloat? = nil) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: sharp.width, height: sharp.height)
        let r = region.integral.intersection(bounds)
        guard !r.isNull, r.width >= 1, r.height >= 1 else { return nil }
        let cell = cell ?? mosaicCell(for: r)
        let source = CIImage(cgImage: sharp).cropped(to: r).clampedToExtent()
        let pixellate = CIFilter.pixellate()
        pixellate.inputImage = source
        pixellate.scale = Float(cell)
        pixellate.center = CGPoint(x: r.minX, y: r.minY)
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = pixellate.outputImage?.clampedToExtent()
        blur.radius = Float(cell / 2)
        guard let output = blur.outputImage?.cropped(to: r) else { return nil }
        return CIContext(options: [.useSoftwareRenderer: false]).createCGImage(output, from: r)
    }

    /// One obscured image for a group of overlapping/touching regions.
    struct ObscuredGroup {
        /// The regions of the group (same coordinate space as the input).
        let regions: [CGRect]
        /// Bounding box of the group, integral, clipped to the image.
        let frame: CGRect
        /// Mosaic+blur of `frame`, computed once for the whole group.
        let image: CGImage
    }

    /// Splits regions into groups of overlapping or touching rects (within `tolerance`) and
    /// obscures each group as ONE image with ONE mosaic grid and cell size (the coarsest any of
    /// its regions needs). Separately obscured patches would meet in hard seams inside each
    /// other's area wherever redactions overlap (e.g. adjacent lines, native + OCR boxes).
    static func obscuredGroups(_ regions: [CGRect], in sharp: CGImage, tolerance: CGFloat = 2) -> [ObscuredGroup]? {
        let bounds = CGRect(x: 0, y: 0, width: sharp.width, height: sharp.height)
        let clipped = regions.map { $0.integral.intersection(bounds) }.filter { !$0.isNull && $0.width >= 1 && $0.height >= 1 }
        var groups: [ObscuredGroup] = []
        for members in connectedGroups(clipped, tolerance: tolerance) {
            let frame = members.dropFirst().reduce(members[0]) { $0.union($1) }.integral.intersection(bounds)
            let cell = members.map(mosaicCell(for:)).max() ?? mosaicCell(for: frame)
            guard let image = obscuredPatch(of: sharp, region: frame, cell: cell) else { return nil }
            groups.append(ObscuredGroup(regions: members, frame: frame, image: image))
        }
        return groups
    }

    /// Connected components of rects that intersect after growing by `tolerance`.
    static func connectedGroups(_ rects: [CGRect], tolerance: CGFloat) -> [[CGRect]] {
        var parent = Array(rects.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        for i in rects.indices {
            for j in rects.indices where j > i {
                if rects[i].insetBy(dx: -tolerance, dy: -tolerance).intersects(rects[j]) {
                    parent[root(i)] = root(j)
                }
            }
        }
        var byRoot: [Int: [CGRect]] = [:]
        var order: [Int] = []
        for i in rects.indices {
            let r = root(i)
            if byRoot[r] == nil { order.append(r) }
            byRoot[r, default: []].append(rects[i])
        }
        return order.compactMap { byRoot[$0] }
    }

    /// Paints every region of `ctx` (pixel coordinates, origin bottom-left) with its obscured
    /// version taken from `sharp` (a snapshot of the same context), group by group.
    static func obscure(_ regions: [CGRect], in ctx: CGContext, from sharp: CGImage) -> Bool {
        guard let groups = obscuredGroups(regions, in: sharp) else { return false }
        for group in groups {
            ctx.saveGState()
            ctx.clip(to: group.regions)
            ctx.draw(group.image, in: group.frame)
            ctx.restoreGState()
        }
        return true
    }
}

/// Writes image-only PDF pages: each bitmap is JPEG-encoded and drawn to fill its page's media
/// box exactly (PDFPage(image:) aspect-fits instead, which misplaces rounded bitmaps on
/// extreme page sizes). Quartz embeds the JPEG data as-is.
@MainActor
final class ImagePDFWriter {
    static let jpegQuality = 0.9

    private let data = NSMutableData()
    private let context: CGContext?

    init() {
        if let consumer = CGDataConsumer(data: data as CFMutableData) {
            context = CGContext(consumer: consumer, mediaBox: nil, nil)
        } else {
            context = nil
        }
    }

    func addPage(_ image: CGImage, size: CGSize) -> Bool {
        guard let context, let jpeg = Self.jpegImage(image) else { return false }
        var box = CGRect(origin: .zero, size: size)
        context.beginPage(mediaBox: &box)
        context.draw(jpeg, in: box)
        context.endPage()
        return true
    }

    func finish() -> PDFDocument? {
        guard let context else { return nil }
        context.closePDF()
        return PDFDocument(data: data as Data)
    }

    private static func jpegImage(_ image: CGImage) -> CGImage? {
        let encoded = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(encoded as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(dest), let provider = CGDataProvider(data: encoded as CFData) else { return nil }
        return CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
