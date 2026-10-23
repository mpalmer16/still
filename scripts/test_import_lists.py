"""Shape and identity tests for the local Lists preparation step."""

from pathlib import Path
import tempfile
import unittest
from zipfile import ZipFile

from import_lists import (
    Artifact, colon_title, identify_format, make_manifest, read_docx, read_odt,
    remove_structural_dashes, split_pieces,
)


WNS = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"


def docx(path, paragraphs, styles=None):
    with ZipFile(path, "w") as archive:
        archive.writestr("word/document.xml", f'<w:document xmlns:w="{WNS}"><w:body>{paragraphs}</w:body></w:document>')
        if styles:
            archive.writestr("word/styles.xml", f'<w:styles xmlns:w="{WNS}">{styles}</w:styles>')


def artifact(paragraphs, filename="1. A.Familiar.Shape..doc"):
    return Artifact(Path(filename), "Notebook/" + filename, "doc", "hash", paragraphs)


class ShapeTest(unittest.TestCase):
    def test_docx_authored_breaks_blank_paragraphs_tabs_and_indents(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "extensionless"
            docx(path, '''
              <w:p><w:r><w:t>A long line that a word processor visually wraps</w:t></w:r></w:p>
              <w:p/>
              <w:p><w:pPr><w:ind w:left="720" w:first-line="720"/></w:pPr>
                <w:r><w:t>branch / one - thought</w:t><w:br/><w:tab/><w:t>another</w:t></w:r></w:p>
              <w:p><w:r><w:t xml:space="preserve">        actual spaces</w:t></w:r></w:p>
              <w:p><w:del><w:r><w:t>deleted words</w:t></w:r></w:del>
                <w:ins><w:r><w:t>remaining words</w:t></w:r></w:ins></w:p>
            ''')
            self.assertEqual(identify_format(path), "docx")
            self.assertEqual(read_docx(path), [
                "A long line that a word processor visually wraps", "",
                "\t\tbranch / one - thought\n\t\tanother", "        actual spaces", "remaining words",
            ])

    def test_docx_style_inheritance_and_paragraph_override(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "styles.docx"
            docx(path, '''<w:p><w:pPr><w:pStyle w:val="Branch"/><w:ind w:firstLine="720"/></w:pPr>
                         <w:r><w:t>words</w:t></w:r></w:p>''', '''
                <w:style w:styleId="Base"><w:pPr><w:ind w:left="720"/></w:pPr></w:style>
                <w:style w:styleId="Branch"><w:basedOn w:val="Base"/></w:style>''')
            self.assertEqual(read_docx(path), ["\t\twords"])

    def test_odt_explicit_spaces_manual_break_and_styled_indentation(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "oddname.doc"
            with ZipFile(path, "w") as archive:
                archive.writestr("mimetype", "application/vnd.oasis.opendocument.text")
                archive.writestr("content.xml", '''
                  <office:document-content
                    xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
                    xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"
                    xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0"
                    xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0">
                    <office:automatic-styles><style:style style:name="Indented">
                      <style:paragraph-properties fo:margin-left="0.5in"/>
                    </style:style></office:automatic-styles>
                    <office:body><office:text>
                      <text:p>words<text:s text:c="3"/>/ <text:span>thoughts</text:span><text:line-break/>again</text:p>
                      <text:p/>
                      <text:p text:style-name="Indented"><text:tab/>branch</text:p>
                    </office:text></office:body>
                  </office:document-content>''')
            self.assertEqual(identify_format(path), "odt")
            self.assertEqual(read_odt(path), ["words   / thoughts\nagain", "", "\t\tbranch"])

    def test_legacy_word_identified_despite_txt_suffix(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "not-text.txt"
            path.write_bytes(bytes.fromhex("d0cf11e0a1b11ae1") + b"legacy word")
            self.assertEqual(identify_format(path), "doc")

    def test_structural_dashes_do_not_touch_internal_dashes_or_slashes(self):
        original = "- one - another / thought\n    - a branch\n    - another branch\n-1 is a number"
        self.assertEqual(remove_structural_dashes(original),
                         "one - another / thought\n    a branch\n    another branch\n-1 is a number")
        self.assertEqual(remove_structural_dashes("-uncertain"), "-uncertain")
        self.assertEqual(remove_structural_dashes("-one\n\t-two\n-three - internal"),
                         "one\n\ttwo\nthree - internal")
        self.assertEqual(remove_structural_dashes("-A tiny sibling", True), "A tiny sibling")

    def test_clear_source_siblings_and_preamble_remain_together(self):
        pieces = split_pieces(artifact([
            "earlier words", "-The attribution", "", "Two:Gears:  or  What:Torque:Did:", "",
            "words\n\tbranch", "", "", "Spare:Bolt:", "", "one final line", "",
        ]))
        self.assertEqual([p["title"] for p in pieces], ["Two:Gears:  or  What:Torque:Did:", "Spare:Bolt:"])
        self.assertEqual(pieces[0]["preamble"], "earlier words\n-The attribution")
        self.assertEqual(pieces[1]["preamble"], "")
        self.assertEqual(pieces[0]["original_body"], "words\n\tbranch")
        self.assertEqual([p["source_order"] for p in pieces], [0, 1])

    def test_title_inside_one_paragraph_of_manual_breaks(self):
        pieces = split_pieces(artifact(["A:Title:\n\nfirst line\n\tbranch\n\nB:Title:\n\nlast line"]))
        self.assertEqual([piece["title"] for piece in pieces], ["A:Title:", "B:Title:"])
        self.assertEqual(pieces[0]["original_body"], "first line\n\tbranch")

    def test_ordinary_title_and_poetic_opening_are_different(self):
        standalone = split_pieces(artifact(["That Test Rig – or – The Way We Sort The Bolts", "", "a line / and a thought"]))[0]
        self.assertEqual(standalone["title"], "That:Test:Rig:Or:The:Way:We:Sort:The:Bolts:")
        self.assertEqual(standalone["original_body"], "a line / and a thought")
        opening = split_pieces(artifact(["We logged", "a spare gear beside the lathe", "", "another line"],
                                      "7 We.Logged.A.Spare.Gear.Beside.The.Lathe..odt"))[0]
        self.assertEqual(opening["title"], "We:Logged:A:Spare:Gear:Beside:The:Lathe:")
        self.assertEqual(opening["original_body"], "We logged\na spare gear beside the lathe\n\nanother line")
        self.assertEqual(colon_title("Don't misplace / the bolt"), "Dont:Misplace:The:Bolt:")
        source_words = split_pieces(artifact(["I'm checking here to see which gear fits the jig", "the test rig"],
                                           "19 I.Checking.Here.To.See.Which.Gear.Fits.The.Jig.odt"))[0]
        self.assertEqual(source_words["title"], "Im:Checking:Here:To:See:Which:Gear:Fits:The:Jig:")

    def test_alternates_merge_locally_while_matching_writing_elsewhere_remains(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            notebook = root / "Notebook"
            other = root / "Other Notebook"
            notebook.mkdir()
            other.mkdir()
            words = '<w:p><w:r><w:t>A:Title:</w:t></w:r></w:p><w:p/><w:p><w:r><w:t>writing</w:t></w:r></w:p>'
            docx(notebook / "1. A.Title.docx", words)
            docx(notebook / "2. A.Title.docx", words)
            docx(other / "1. A.Title.docx", words)
            with ZipFile(notebook / "1. A.Title.odt", "w") as archive:
                archive.writestr("mimetype", "application/vnd.oasis.opendocument.text")
                archive.writestr("content.xml", '''<office:document-content
                  xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
                  xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
                  <office:body><office:text><text:p>A:Title:</text:p><text:p/><text:p>writing</text:p>
                  </office:text></office:body></office:document-content>''')
            manifest = make_manifest(root)
            self.assertEqual(len(manifest["entries"]), 3)
            self.assertEqual(manifest["report"]["alternate_artifacts_merged"], 1)
            self.assertEqual(len(set(entry["source_key"] for entry in manifest["entries"])), 3)
            merged = next(entry for entry in manifest["entries"] if entry["source_group"] == "Notebook/1-a-title")
            self.assertEqual(len(merged["source"]["artifacts"]), 2)
            self.assertEqual(merged["source"]["original_body"], "writing")
            next_artifact = next(entry for entry in manifest["entries"] if entry["source_group"] == "Notebook/2-a-title")
            self.assertEqual(merged["source_order"], 0)
            self.assertEqual(next_artifact["source_order"], 100)
            self.assertEqual(next_artifact["source"]["artifact_order"], 1)


if __name__ == "__main__":
    unittest.main()
