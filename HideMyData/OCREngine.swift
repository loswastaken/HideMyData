import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Vision

struct OCRLine {
    let text: String
    let candidate: RecognizedText
}

struct OCRPage {
    let lines: [OCRLine]
    let combinedText: String
    private let lineStartOffsets: [Int]  // char offset in combinedText where each line starts
    /// Maps Vision's normalized boxes (of the image actually recognised, possibly re-oriented)
    /// back to normalized coordinates of the original image.
    let toOriginal: CGAffineTransform

    init(lines: [OCRLine], toOriginal: CGAffineTransform = .identity) {
        self.lines = lines
        self.toOriginal = toOriginal
        var combined = ""
        var starts: [Int] = []
        for (i, line) in lines.enumerated() {
            starts.append(combined.count)
            combined += line.text
            if i < lines.count - 1 { combined += "\n" }
        }
        self.combinedText = combined
        self.lineStartOffsets = starts
    }

    func normalizedBoxes(start: Int, end: Int) -> [CGRect] {
        guard start >= 0, end <= combinedText.count, start < end else { return [] }
        var rects: [CGRect] = []
        for (i, line) in lines.enumerated() {
            let lineStart = lineStartOffsets[i]
            let lineEnd = lineStart + line.text.count
            let lo = max(start, lineStart)
            let hi = min(end, lineEnd)
            guard lo < hi else { continue }

            let localStartOffset = lo - lineStart
            let localEndOffset = hi - lineStart
            let s = line.text.index(line.text.startIndex, offsetBy: localStartOffset)
            let e = line.text.index(line.text.startIndex, offsetBy: localEndOffset)
            if let region = line.candidate.boundingBox(for: s..<e) {
                rects.append(region.boundingBox.cgRect.applying(toOriginal))
            }
        }
        return rects
    }

    /// True when most recognised lines run vertically in an image of `pixelSize` (a page
    /// scanned sideways). Vision reads such text, but less reliably than upright text.
    func isMostlySideways(pixelSize: CGSize) -> Bool {
        var vertical = 0, horizontal = 0
        for line in lines where line.text.count >= 4 {
            let text = line.text
            guard let box = line.candidate.boundingBox(for: text.startIndex..<text.endIndex)?.boundingBox.cgRect else { continue }
            if box.height * pixelSize.height > box.width * pixelSize.width { vertical += 1 } else { horizontal += 1 }
        }
        return vertical > horizontal
    }
}

enum OCREngine {
    /// `languageCorrection` defaults to the original behaviour (on). With it, words read better
    /// but identifiers can be "corrected" (999-88-7777 → 999.88.7777); without it the reverse.
    /// The PDF redactor runs both and uses the union.
    static func recognize(_ image: CGImage, languageCorrection: Bool = true) async throws -> OCRPage {
        try await recognize(image, languageCorrection: languageCorrection, toOriginal: .identity)
    }

    /// Recognises `image` turned to `orientation` (e.g. `.right` for a page scanned sideways);
    /// the returned page's boxes are mapped back to the unturned image.
    static func recognize(_ image: CGImage, orientation: CGImagePropertyOrientation, languageCorrection: Bool) async throws -> OCRPage {
        let source = CIImage(cgImage: image)
        let turned = source.oriented(orientation)
        let extent = turned.extent
        guard let cg = CIContext().createCGImage(turned, from: extent) else {
            throw HMDError.message("Could not re-orient the page for OCR")
        }
        let toOriginal = CGAffineTransform(scaleX: extent.width, y: extent.height)
            .concatenating(CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .concatenating(source.orientationTransform(for: orientation).inverted())
            .concatenating(CGAffineTransform(scaleX: 1 / CGFloat(image.width), y: 1 / CGFloat(image.height)))
        return try await recognize(cg, languageCorrection: languageCorrection, toOriginal: toOriginal)
    }

    private static func recognize(_ image: CGImage, languageCorrection: Bool, toOriginal: CGAffineTransform) async throws -> OCRPage {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = languageCorrection
        request.automaticallyDetectsLanguage = true

        let observations = try await request.perform(on: image)
        let lines: [OCRLine] = observations.compactMap { obs in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            return OCRLine(text: candidate.string, candidate: candidate)
        }
        return OCRPage(lines: lines, toOriginal: toOriginal)
    }
}
