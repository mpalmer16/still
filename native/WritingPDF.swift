import AppKit
import CoreText
import Foundation

/// Renders read-only writing as a paginated, searchable PDF without involving
/// the editor view or a print panel.
enum WritingPDF {
    struct Segment {
        let body: String
        let inset: Bool

        init(body: String, inset: Bool = false) {
            self.body = body
            self.inset = inset
        }
    }

    enum RenderError: LocalizedError {
        case couldNotCreatePDF
        case layoutMadeNoProgress

        var errorDescription: String? {
            switch self {
            case .couldNotCreatePDF:
                return "Still could not create the PDF."
            case .layoutMadeNoProgress:
                return "Still could not lay out all of the writing in the PDF."
            }
        }
    }

    private static let pageSize = CGSize(width: 612, height: 792)
    private static let margin: CGFloat = 54

    static func render(title: String, segments: [Segment]) throws -> Data {
        let text = attributedWriting(segments)
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let pdfData = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        var metadata: [CFString: Any] = [:]
        if !title.isEmpty {
            metadata[kCGPDFContextTitle] = title
        }
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, metadata as CFDictionary) else {
            throw RenderError.couldNotCreatePDF
        }

        let layoutRect = CGRect(
            x: margin,
            y: margin,
            width: pageSize.width - margin * 2,
            height: pageSize.height - margin * 2
        )
        var location = 0
        let length = text.length

        // Keep even empty writing as a valid, single blank page.
        repeat {
            context.beginPDFPage(nil)
            if location < length {
                let path = CGPath(rect: layoutRect, transform: nil)
                let frame = CTFramesetterCreateFrame(
                    framesetter,
                    CFRange(location: location, length: 0),
                    path,
                    nil
                )
                let visible = CTFrameGetVisibleStringRange(frame)
                guard visible.length > 0 else {
                    context.endPDFPage()
                    context.closePDF()
                    throw RenderError.layoutMadeNoProgress
                }
                CTFrameDraw(frame, context)
                location += visible.length
            }
            context.endPDFPage()
        } while location < length

        context.closePDF()
        return pdfData as Data
    }

    private static func attributedWriting(_ segments: [Segment]) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let font = CTFontCreateWithName("Georgia" as CFString, 12, nil)

        for segment in segments {
            let normalizedBody = segment.body
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            let lines = normalizedBody.components(separatedBy: "\n")
            for (lineIndex, line) in lines.enumerated() {
                let charWrap = hasOverwideToken(in: line, font: font, inset: segment.inset)
                let attributes = attributes(font: font, inset: segment.inset, charWrap: charWrap)
                result.append(NSAttributedString(string: line, attributes: attributes))
                if lineIndex < lines.count - 1 {
                    result.append(NSAttributedString(string: "\n", attributes: attributes))
                }
            }
        }
        return result
    }

    private static func attributes(font: CTFont, inset: Bool, charWrap: Bool) -> [NSAttributedString.Key: Any] {
        var layout = ParagraphLayout(
            lineAdjustment: 4,
            headIndent: inset ? 18 : 0,
            firstIndent: inset ? 18 : 0,
            paragraphSpacing: 3,
            lineBreakMode: charWrap ? .byCharWrapping : .byWordWrapping
        )
        let paragraphStyle = withUnsafeBytes(of: &layout) { bytes -> CTParagraphStyle in
            let base = bytes.baseAddress!
            let size = MemoryLayout<CGFloat>.size
            let settings = [
                CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: size, value: base.advanced(by: MemoryLayout<ParagraphLayout>.offset(of: \.lineAdjustment)!)),
                CTParagraphStyleSetting(spec: .headIndent, valueSize: size, value: base.advanced(by: MemoryLayout<ParagraphLayout>.offset(of: \.headIndent)!)),
                CTParagraphStyleSetting(spec: .firstLineHeadIndent, valueSize: size, value: base.advanced(by: MemoryLayout<ParagraphLayout>.offset(of: \.firstIndent)!)),
                CTParagraphStyleSetting(spec: .paragraphSpacing, valueSize: size, value: base.advanced(by: MemoryLayout<ParagraphLayout>.offset(of: \.paragraphSpacing)!)),
                CTParagraphStyleSetting(spec: .lineBreakMode, valueSize: MemoryLayout<CTLineBreakMode>.size, value: base.advanced(by: MemoryLayout<ParagraphLayout>.offset(of: \.lineBreakMode)!))
            ]
            return CTParagraphStyleCreate(settings, settings.count)
        }
        return [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.08, alpha: 1),
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraphStyle
        ]
    }

    private static func hasOverwideToken(in paragraph: String, font: CTFont, inset: Bool) -> Bool {
        let width = pageSize.width - margin * 2 - (inset ? 18 : 0)
        return paragraph.split(whereSeparator: \.isWhitespace).contains { token in
            let attributedToken = NSAttributedString(string: String(token), attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font
            ])
            return CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributedToken), nil, nil, nil) > width
        }
    }

    private struct ParagraphLayout {
        var lineAdjustment: CGFloat
        var headIndent: CGFloat
        var firstIndent: CGFloat
        var paragraphSpacing: CGFloat
        var lineBreakMode: CTLineBreakMode
    }

}
