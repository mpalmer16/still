import Foundation
import PDFKit

@main
struct WritingPDFTests {
    static func main() throws {
        let prose = "First line with curly quotes ‘kept exact’.\n\n    Indented words stay indented.\nA final thought with an emoji 🌱."
        let poem = "  A small poem\n    keeps its own line\n\n  and its blank space."
        let pdf = try WritingPDF.render(
            title: "A quiet title",
            segments: [
                WritingPDF.Segment(body: prose + "\n\n"),
                WritingPDF.Segment(body: poem + "\n\n", inset: true),
                WritingPDF.Segment(body: "After poem.")
            ]
        )
        guard let document = PDFDocument(data: pdf) else {
            fatalError("Renderer should return a readable PDF")
        }
        precondition(document.pageCount == 1, "Short writing should fit on one page")
        let extracted = document.string ?? ""
        for phrase in ["First line", "curly quotes", "Indented words", "final thought", "small poem", "blank space"] {
            precondition(extracted.contains(phrase), "PDF text should retain: \(phrase)")
        }
        precondition(extracted.contains("🌱"), "Unicode characters outside the primary serif font should use a fallback font")
        precondition(!extracted.contains("A quiet title"), "The document title belongs in metadata, not in the writing")
        let title = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        precondition(title == "A quiet title", "The PDF document title should be metadata")

        let boundaryPDF = try WritingPDF.render(title: "Boundaries", segments: [
            WritingPDF.Segment(body: "Before\n"),
            WritingPDF.Segment(body: "Poem" , inset: true),
            WritingPDF.Segment(body: "\nAfter")
        ])
        guard let boundaryDocument = PDFDocument(data: boundaryPDF) else {
            fatalError("Segment boundary render should return a readable PDF")
        }
        let boundaryLines = (boundaryDocument.string ?? "").split(whereSeparator: \.isNewline).map(String.init)
        precondition(boundaryDocument.pageCount == 1, "Three short segments should fit on one page")
        precondition(boundaryLines == ["Before", "Poem", "After"],
                     "Segment boundaries should add no text or blank lines beyond authored delimiters")

        let firstPoem = "First poem\nwith two lines."
        let secondPoem = "Second poem\nwith its own line."
        let poemsPDF = try WritingPDF.render(title: "Two poems", segments: [
            WritingPDF.Segment(body: firstPoem),
            WritingPDF.Segment(body: secondPoem, pageBreakBefore: true)
        ])
        guard let poemsDocument = PDFDocument(data: poemsPDF) else {
            fatalError("Two-poem render should return a readable PDF")
        }
        precondition(poemsDocument.pageCount == 2, "Each marked poem should start on its own page")
        let firstPage = poemsDocument.page(at: 0)?.string ?? ""
        let secondPage = poemsDocument.page(at: 1)?.string ?? ""
        precondition(firstPage.contains("First poem") && !firstPage.contains("Second poem"),
                     "The first poem should stay on the first page")
        precondition(secondPage.contains("Second poem") && !secondPage.contains("First poem"),
                     "The marked poem should begin on the second page")
        let poemText = poemsDocument.string ?? ""
        precondition(poemText.contains(firstPoem) && poemText.contains(secondPoem),
                     "Page breaks must preserve each poem's authored line breaks and words")
        precondition(!poemText.contains("\u{000C}") && !poemText.contains("\u{200B}"),
                     "Page breaks must not insert control or invisible characters into the writing")

        let markedFirstPDF = try WritingPDF.render(title: "Marked first", segments: [
            WritingPDF.Segment(body: firstPoem, pageBreakBefore: true)
        ])
        guard let markedFirstDocument = PDFDocument(data: markedFirstPDF) else {
            fatalError("A marked first poem should return a readable PDF")
        }
        precondition(markedFirstDocument.pageCount == 1,
                     "A page break before the first source should not create a blank leading page")

        let lineEndingPDF = try WritingPDF.render(title: "Line endings", segments: [
            WritingPDF.Segment(body: "CRLF line\r\nCR line\rLF line")
        ])
        guard let lineEndingDocument = PDFDocument(data: lineEndingPDF) else {
            fatalError("Line ending render should return a readable PDF")
        }
        let lineEndingLines = (lineEndingDocument.string ?? "").split(whereSeparator: \.isNewline).map(String.init)
        precondition(lineEndingLines == ["CRLF line", "CR line", "LF line"],
                     "CRLF and CR should each become one logical PDF line break")

        let longWord = String(repeating: "W", count: 2_000)
        let longBody = (1...240).map { "Paragraph \($0): a line of writing that remains searchable after page layout." }
            .joined(separator: "\n\n") + "\n\n" + longWord
        let longPDF = try WritingPDF.render(title: "Long writing", segments: [WritingPDF.Segment(body: longBody, inset: true)])
        guard let longDocument = PDFDocument(data: longPDF) else {
            fatalError("Multipage render should return a readable PDF")
        }
        precondition(longDocument.pageCount > 1, "Long writing should paginate")
        let longExtracted = longDocument.string ?? ""
        precondition(longExtracted.contains("Paragraph 1:"), "The first page should retain its opening words")
        precondition(longExtracted.contains("Paragraph 240:"), "The final page should retain the final words")
        let normalizedLongExtracted = longExtracted.replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        precondition(normalizedLongExtracted.contains("a line of writing that remains searchable after page layout."),
                     "Ordinary prose should retain word-boundary wrapping")
        precondition(normalizedLongExtracted.contains(longWord),
                     "A very long unbroken word should reconstruct exactly after line wrapping")
        precondition(!longExtracted.contains("\u{200B}"), "PDF text must not add invisible characters to authored words")

        let lastParagraph = "The long poem ends with this exact final line."
        let followingPoem = "A new short poem."
        let longThenShortPDF = try WritingPDF.render(title: "Long and short", segments: [
            WritingPDF.Segment(body: longBody + "\n\n" + lastParagraph, inset: true),
            WritingPDF.Segment(body: followingPoem, pageBreakBefore: true)
        ])
        guard let longThenShortDocument = PDFDocument(data: longThenShortPDF) else {
            fatalError("Long-poem render should return a readable PDF")
        }
        precondition(longThenShortDocument.pageCount > longDocument.pageCount,
                     "A marked poem after a long poem should receive a new page")
        let finalPage = longThenShortDocument.page(at: longThenShortDocument.pageCount - 1)?.string ?? ""
        precondition(finalPage.contains(followingPoem), "The following short poem should start on the final page")
        precondition(!finalPage.contains("Paragraph 240:") && !finalPage.contains(lastParagraph),
                     "The preceding long poem should not share the short poem's page")
        let longThenShortText = longThenShortDocument.string ?? ""
        precondition(longThenShortText.contains(lastParagraph) && longThenShortText.contains(followingPoem),
                     "Pagination should preserve the final words of both poems")
        precondition(!longThenShortText.contains("\u{000C}") && !longThenShortText.contains("\u{200B}"),
                     "Pagination should not add control or invisible characters to authored words")

        let emptyPDF = try WritingPDF.render(title: "Empty", segments: [])
        guard let emptyDocument = PDFDocument(data: emptyPDF) else {
            fatalError("Empty writing should still produce a readable PDF")
        }
        precondition(emptyDocument.pageCount == 1, "Empty writing should produce one blank page")
        print("Writing PDF checks passed: metadata title, searchable Unicode prose and poem text, and multipage pagination.")
    }
}
