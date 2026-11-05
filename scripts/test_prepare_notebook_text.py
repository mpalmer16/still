"""Synthetic safety and fidelity tests for notebook text preparation."""
from __future__ import annotations

from pathlib import Path
import hashlib
import tempfile
import unittest
from zipfile import ZipFile
from unittest.mock import patch

from prepare_notebook_text import discover, run


W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"


def docx(path: Path, body: str, styles: str | None = None) -> None:
    with ZipFile(path, "w") as z:
        z.writestr("word/document.xml", f'<w:document xmlns:w="{W}" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><w:body>{body}</w:body></w:document>')
        if styles is not None:
            z.writestr("word/styles.xml", f'<w:styles xmlns:w="{W}">{styles}</w:styles>')


def docx_with_notes(path: Path, body: str, notes: str) -> None:
    docx(path, body)
    with ZipFile(path, "a") as z:
        z.writestr("word/footnotes.xml", f'<w:footnotes xmlns:w="{W}">{notes}</w:footnotes>')


def odt(path: Path, paragraphs: list[str]) -> None:
    body = "".join(f"<text:p>{value}</text:p>" for value in paragraphs)
    with ZipFile(path, "w") as z:
        z.writestr("mimetype", "application/vnd.oasis.opendocument.text")
        z.writestr("content.xml", f'''<office:document-content
          xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
          xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
          <office:body><office:text>{body}</office:text></office:body>
          </office:document-content>''')


class PrepareNotebookTextTest(unittest.TestCase):
    def test_txt_bytes_and_docx_authored_spacing_survive_without_title_inference(self):
        with tempfile.TemporaryDirectory() as d:
            base = Path(d)
            source = base / "Notebook A"
            source.mkdir()
            txt = source / "title-looking-name.txt"
            txt.write_bytes("  exact\r\n\r\n\twords  \n".encode())
            word = source / "2. Filename.docx"
            docx(word, '<w:p><w:r><w:t xml:space="preserve">  authored  </w:t><w:br/><w:tab/><w:t>next</w:t></w:r></w:p><w:p/><w:p><w:r><w:t>last</w:t></w:r></w:p>')
            before = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in (txt, word)}
            plan = run([source], base / "Still Writing")
            self.assertEqual(plan["counts"]["ready"], 2)
            self.assertFalse((base / "Still Writing").exists())
            report = run([source], base / "Still Writing", write=True)
            out_txt = base / "Still Writing/Notebook A/title-looking-name.txt"
            out_docx = base / "Still Writing/Notebook A/2. Filename.txt"
            self.assertEqual(out_txt.read_bytes(), txt.read_bytes())
            self.assertEqual(out_docx.read_text(), "  authored  \n\tnext\n\nlast")
            self.assertEqual(before, {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in before})
            self.assertEqual(report["written"], 2)

    def test_gdoc_is_reported_but_not_read_or_written_without_allow_pending(self):
        with tempfile.TemporaryDirectory() as d:
            base = Path(d); source = base / "Early"; source.mkdir()
            ref = source / "link.gdoc"; ref.write_text('{"url":"secret ref"}')
            (source / "piece.txt").write_text("words")
            plan = run([source], base / "out")
            self.assertEqual(plan["counts"]["pending"], 1)
            with self.assertRaises(ValueError):
                run([source], base / "out", write=True)
            self.assertFalse((base / "out").exists())
            result = run([source], base / "out", write=True, allow_pending=True)
            self.assertEqual(result["written"], 1)
            self.assertFalse((base / "out/Early/link.txt").exists())

    def test_same_stem_and_existing_destination_are_explicit_conflicts(self):
        with tempfile.TemporaryDirectory() as d:
            base = Path(d); source = base / "Notebook"; source.mkdir()
            (source / "same.txt").write_text("one")
            docx(source / "same.docx", '<w:p><w:r><w:t>two</w:t></w:r></w:p>')
            plan = discover([source], base / "out")
            self.assertTrue(all(row["status"] == "blocked" for row in plan))
            with self.assertRaises(ValueError):
                run([source], base / "out", write=True)
            resolved = run([source], base / "resolved", write=True,
                           keep_format_on_collision=True)
            self.assertEqual(resolved["written"], 2)
            self.assertEqual((base / "resolved/Notebook/same.docx.txt").read_text(), "two")
            self.assertEqual((base / "resolved/Notebook/same.txt.txt").read_text(), "one")
            clean = base / "Clean"; clean.mkdir(); (clean / "words.txt").write_text("first")
            run([clean], base / "existing", write=True)
            (clean / "words.txt").write_text("changed")
            with self.assertRaises(FileExistsError):
                run([clean], base / "existing", write=True)
            self.assertEqual((base / "existing/Clean/words.txt").read_text(), "first")

    def test_docx_table_is_blocked_as_lossy_shape(self):
        with tempfile.TemporaryDirectory() as d:
            base = Path(d); source = base / "Notebook"; source.mkdir()
            docx(source / "table.docx", '<w:tbl/>')
            report = run([source], base / "out")
            self.assertEqual(report["counts"]["blocked"], 1)
            self.assertIn("table", report["files"][0]["reason"])

    def test_ancillary_files_skipped_and_gdoc_references_never_read(self):
        with tempfile.TemporaryDirectory() as d:
            base = Path(d); source = base / "Notebook"; source.mkdir()
            (source / ".DS_Store").write_bytes(b"binary")
            (source / "archive.zip").write_bytes(b"binary")
            (source / "reference.gdoc").write_bytes(b"not json and must not parse")
            rows = discover([source], base / "out")
            self.assertEqual([r["status"] for r in rows], ["skipped", "skipped", "pending"])

    def test_empty_odt_header_is_accepted_but_nonempty_header_is_blocked(self):
        def make(path, header):
            with ZipFile(path, "w") as z:
                z.writestr("mimetype", "application/vnd.oasis.opendocument.text")
                z.writestr("content.xml", '''<office:document-content
                  xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
                  xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
                  <office:body><office:text><text:p>words</text:p></office:text></office:body>
                  </office:document-content>''')
                z.writestr("styles.xml", f'''<office:document-styles
                  xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
                  xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
                  <office:master-styles><style:master-page xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0">
                  <style:header>{header}</style:header></style:master-page></office:master-styles></office:document-styles>''')
        with tempfile.TemporaryDirectory() as d:
            base = Path(d); source = base / "Notebook"; source.mkdir()
            make(source / "empty.odt", "")
            make(source / "header.odt", "<text:p>lost words</text:p>")
            rows = discover([source], base / "out")
            self.assertEqual([r["status"] for r in rows], ["ready", "blocked"])
            self.assertIn("nonempty headers", rows[1]["reason"])

    def test_empty_docx_default_header_is_accepted_but_nonempty_header_is_blocked(self):
        with tempfile.TemporaryDirectory() as d:
            base = Path(d); source = base / "Notebook"; source.mkdir()
            for name, words in (("empty.docx", ""), ("header.docx", "<w:p><w:r><w:t>header text</w:t></w:r></w:p>")):
                with ZipFile(source / name, "w") as z:
                    z.writestr("word/document.xml", f'<w:document xmlns:w="{W}"><w:body><w:p><w:r><w:t>body</w:t></w:r></w:p></w:body></w:document>')
                    z.writestr("word/header1.xml", f'<w:hdr xmlns:w="{W}">{words}</w:hdr>')
            rows = discover([source], base / "out")
            self.assertEqual([r["status"] for r in rows], ["ready", "blocked"])
            self.assertIn("nonempty headers", rows[1]["reason"])

    def test_invalid_txt_is_blocked_during_preflight_without_destination(self):
        with tempfile.TemporaryDirectory() as d:
            base = Path(d); source = base / "Notebook"; source.mkdir()
            (source / "invalid.txt").write_bytes(b"\xff")
            report = run([source], base / "out")
            self.assertEqual(report["counts"]["blocked"], 1)
            self.assertIn("preflight extraction failed", report["files"][0]["reason"])
            with self.assertRaises(ValueError):
                run([source], base / "out", write=True)
            self.assertFalse((base / "out").exists())

    def test_docx_hyperlink_is_blocked_instead_of_dropping_target(self):
        with tempfile.TemporaryDirectory() as d:
            base = Path(d); source = base / "Notebook"; source.mkdir()
            docx(source / "link.docx", '<w:p><w:hyperlink r:id="rId1"><w:r><w:t>linked words</w:t></w:r></w:hyperlink></w:p>')
            report = run([source], base / "out")
            self.assertEqual(report["counts"]["blocked"], 1)
            self.assertIn("link", report["files"][0]["reason"])

    def test_opt_in_footnotes_preserve_inline_position_text_and_breaks(self):
        with tempfile.TemporaryDirectory() as d:
            base = Path(d); source = base / "Notebook"; source.mkdir()
            docx_with_notes(source / "poem.docx",
                '<w:p><w:r><w:t>before </w:t><w:footnoteReference w:id="1"/><w:t> after</w:t></w:r></w:p>',
                '<w:footnote w:id="1"><w:p><w:r><w:t>first line</w:t><w:br/><w:t>second</w:t></w:r></w:p><w:p><w:r><w:t>last paragraph</w:t></w:r></w:p></w:footnote>')
            self.assertEqual(run([source], base / "default")['counts']['blocked'], 1)
            report = run([source], base / "out", write=True, include_footnotes=True)
            self.assertEqual(report['written'], 1)
            text = (base / "out/Notebook/poem.txt").read_text()
            self.assertEqual(text, "before [1] after\n[1] first line\nsecond\n[1] last paragraph")

    def test_opt_in_footnotes_reject_missing_references_and_unsupported_note_content(self):
        with tempfile.TemporaryDirectory() as d:
            base = Path(d); source = base / "Notebook"; source.mkdir()
            docx_with_notes(source / "missing.docx", '<w:p><w:r><w:footnoteReference w:id="8"/></w:r></w:p>',
                            '<w:footnote w:id="2"><w:p><w:r><w:t>unmatched</w:t></w:r></w:p></w:footnote>')
            docx_with_notes(source / "link.docx", '<w:p><w:r><w:footnoteReference w:id="1"/></w:r></w:p>',
                            '<w:footnote w:id="1"><w:p><w:hyperlink><w:r><w:t>linked</w:t></w:r></w:hyperlink></w:p></w:footnote>')
            report = run([source], base / "out", include_footnotes=True)
            self.assertEqual(report['counts']['blocked'], 2)
            self.assertTrue(any('no matching note' in row['reason'] for row in report['files']))
            self.assertTrue(any('unsupported structures' in row['reason'] for row in report['files']))

    def test_opt_in_footnotes_reject_unreferenced_text_missing_ids_and_custom_marks(self):
        with tempfile.TemporaryDirectory() as d:
            base = Path(d); source = base / "Notebook"; source.mkdir()
            docx_with_notes(source / "orphan.docx", '<w:p><w:r><w:t>body</w:t></w:r></w:p>',
                '<w:footnote w:id="1"><w:p><w:r><w:t>orphan words</w:t></w:r></w:p></w:footnote>')
            docx_with_notes(source / "no-id.docx", '<w:p><w:r><w:footnoteReference/></w:r></w:p>',
                '<w:footnote w:id="1"><w:p><w:r><w:t>words</w:t></w:r></w:p></w:footnote>')
            docx_with_notes(source / "custom.docx", '<w:p><w:r><w:footnoteReference w:id="1" w:customMarkFollows="1"/></w:r></w:p>',
                '<w:footnote w:id="1"><w:p><w:r><w:t>words</w:t></w:r></w:p></w:footnote>')
            report = run([source], base / "out", include_footnotes=True)
            self.assertEqual(report['counts']['blocked'], 3)
            self.assertTrue(any('no matching reference' in row['reason'] for row in report['files']))
            self.assertTrue(any('no id' in row['reason'] for row in report['files']))
            self.assertTrue(any('custom footnote marks' in row['reason'] for row in report['files']))

    def test_opt_in_footnotes_ignore_word_separator_system_notes(self):
        with tempfile.TemporaryDirectory() as d:
            base = Path(d); source = base / "Notebook"; source.mkdir()
            docx_with_notes(source / "ordinary.docx",
                '<w:p><w:r><w:footnoteReference w:id="0"/></w:r></w:p>',
                '<w:footnote w:type="separator" w:id="-1"><w:p><w:r><w:separator/></w:r></w:p></w:footnote>'
                '<w:footnote w:type="continuationSeparator" w:id="-2"><w:p><w:r><w:continuationSeparator/></w:r></w:p></w:footnote>'
                '<w:footnote w:id="0"><w:p><w:r><w:footnoteRef/><w:t>note words</w:t></w:r></w:p></w:footnote>')
            report = run([source], base / "out", write=True, include_footnotes=True)
            self.assertEqual(report['written'], 1)
            self.assertEqual((base / "out/Notebook/ordinary.txt").read_text(), "[0]\n[0] note words")

    def test_explicit_title_style_is_reported_as_evidence_without_renaming_text(self):
        with tempfile.TemporaryDirectory() as d:
            base = Path(d); source = base / "Notebook"; source.mkdir()
            docx(source / "ordinary-name.docx",
                 '<w:p><w:pPr><w:pStyle w:val="TitleStyle"/></w:pPr><w:r><w:t>authored title wording</w:t></w:r></w:p>',
                 '<w:style w:type="paragraph" w:styleId="TitleStyle"><w:name w:val="Title"/></w:style>')
            report = run([source], base / "out")
            self.assertEqual(report["explicit_title_style_paragraphs"], {"Title": 1})
            self.assertEqual(report["files"][0]["evidence"]["explicit_title_style_locations"],
                             [{"paragraph_index": 0, "style": "Title"}])
            self.assertEqual(Path(report["files"][0]["output"]).name, "ordinary-name.txt")
            self.assertFalse((base / "out").exists())

    def test_doc_content_signature_wins_over_txt_extension(self):
        with tempfile.TemporaryDirectory() as d:
            base = Path(d); source = base / "Notebook"; source.mkdir()
            legacy = source / "54 TEST.txt"
            legacy.write_bytes(bytes.fromhex("d0cf11e0a1b11ae1") + b"synthetic OLE DOC")
            docx_xml = '<w:p><w:r><w:t>converted legacy words</w:t></w:r></w:p>'

            def fake_textutil(command, **kwargs):
                target = Path(command[command.index("-output") + 1])
                docx(target, docx_xml)

            with patch("prepare_notebook_text.subprocess.run", side_effect=fake_textutil):
                plan = run([source], base / "out")
            self.assertEqual(plan["counts"]["ready"], 1)
            self.assertEqual(plan["files"][0]["format"], "doc")
            self.assertEqual(plan["files"][0]["output"].endswith("54 TEST.txt"), True)
            self.assertFalse((base / "out").exists())

    def test_source_destination_overlap_and_symlink_entries_are_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            base = Path(d); source = base / "Notebook"; source.mkdir()
            (source / "words.txt").write_text("words")
            with self.assertRaises(ValueError):
                run([source], source / "Still Writing", write=True)
            outside = base / "outside.txt"; outside.write_text("leave alone")
            try:
                (source / "linked.txt").symlink_to(outside)
            except OSError:
                self.skipTest("symlinks unavailable")
            report = run([source], base / "out")
            linked = next(row for row in report["files"] if row["source"].endswith("linked.txt"))
            self.assertEqual(linked["status"], "blocked")
            self.assertIn("symlink", linked["reason"])
            self.assertEqual(outside.read_text(), "leave alone")

    def test_exact_same_stem_extractions_keep_one_and_report_duplicate(self):
        with tempfile.TemporaryDirectory() as d:
            base = Path(d); source = base / "Notebook"; source.mkdir()
            docx(source / "same.docx", '<w:p><w:r><w:t>words</w:t></w:r></w:p><w:p/><w:p><w:r><w:t>ending</w:t></w:r></w:p>')
            odt(source / "same.odt", ["words", "", "ending"])
            report = run([source], base / "out", write=True, deduplicate_identical=True)
            self.assertEqual(report["counts"]["ready"], 1)
            self.assertEqual(report["counts"]["duplicate"], 1)
            self.assertEqual(report["duplicate_count"], 1)
            self.assertEqual(report["written"], 1)
            self.assertEqual((base / "out/Notebook/same.txt").read_text(), "words\n\nending")
            duplicate = next(row for row in report["files"] if row["status"] == "duplicate")
            self.assertEqual(duplicate["duplicate_of"]["output"], str((base / "out/Notebook/same.txt").resolve()))

    def test_same_stem_with_different_blank_lines_keeps_both_formats(self):
        with tempfile.TemporaryDirectory() as d:
            base = Path(d); source = base / "Notebook"; source.mkdir()
            docx(source / "same.docx", '<w:p><w:r><w:t>words</w:t></w:r></w:p><w:p/><w:p><w:r><w:t>ending</w:t></w:r></w:p>')
            odt(source / "same.odt", ["words", "ending"])
            report = run([source], base / "out", write=True, deduplicate_identical=True)
            self.assertEqual(report["counts"]["ready"], 2)
            self.assertEqual(report["counts"]["duplicate"], 0)
            self.assertEqual(report["written"], 2)
            self.assertEqual((base / "out/Notebook/same.docx.txt").read_text(), "words\n\nending")
            self.assertEqual((base / "out/Notebook/same.odt.txt").read_text(), "words\nending")

    def test_identical_text_with_different_names_is_never_deduplicated(self):
        with tempfile.TemporaryDirectory() as d:
            base = Path(d); source = base / "Notebook"; source.mkdir()
            (source / "first.txt").write_text("same words")
            (source / "second.txt").write_text("same words")
            report = run([source], base / "out", write=True, deduplicate_identical=True)
            self.assertEqual(report["counts"]["ready"], 2)
            self.assertEqual(report["duplicate_count"], 0)
            self.assertEqual(report["written"], 2)


if __name__ == "__main__":
    unittest.main()
