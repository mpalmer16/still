#!/usr/bin/env python3
"""Preflight and prepare local notebook documents as ordinary UTF-8 text.

Default mode inspects and extracts every supported file into a temporary area,
then prints a plan. It never creates the destination. Use --write only after
review. Extraction uses import_lists.py's low-level DOCX/ODT paragraph readers;
it never infers titles, splits pieces, removes dashes, normalizes whitespace,
or merges matching content.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from zipfile import BadZipFile, ZipFile

from import_lists import identify_format, read_docx, read_odt


SUPPORTED = {"doc", "docx", "odt"}
WORD = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"
WORD_NS = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
ODT_TEXT = "{urn:oasis:names:tc:opendocument:xmlns:text:1.0}"
ODT_STYLE = "{urn:oasis:names:tc:opendocument:xmlns:style:1.0}"


def absolute(path: Path) -> Path:
    return Path(os.path.abspath(path))


def symlink_component(path: Path) -> Path | None:
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current = current / part
        if current.is_symlink():
            # macOS exposes these standard locations through canonical aliases.
            aliases = {"/var": Path("/private/var"), "/tmp": Path("/private/tmp")}
            if str(current) in aliases and current.resolve() == aliases[str(current)]:
                continue
            return current
    return None


def validate_paths(sources: list[Path], destination: Path) -> tuple[list[Path], Path]:
    lexical_sources = [absolute(root) for root in sources]
    lexical_destination = absolute(destination)
    bad = symlink_component(lexical_destination)
    if bad:
        raise ValueError(f"destination path contains symlink component: {bad}")
    for root in lexical_sources:
        bad = symlink_component(root)
        if bad:
            raise ValueError(f"source root path contains symlink component: {bad}")
    normalized_sources = [root.resolve(strict=False) for root in lexical_sources]
    normalized_destination = lexical_destination.resolve(strict=False)
    for root in normalized_sources:
        if normalized_destination == root or normalized_destination in root.parents or root in normalized_destination.parents:
            raise ValueError(f"destination overlaps source root: {root}")
    return normalized_sources, normalized_destination


def meaningful_text(element: ET.Element) -> bool:
    return any((node.text or "").strip() for node in element.iter())


def inspect(path: Path, include_footnotes: bool = False) -> tuple[str | None, str | None, dict]:
    """Identify input and reject structures whose meaning readers would omit."""
    try:
        fmt = identify_format(path)
    except OSError as exc:
        return None, f"cannot read source: {exc}", {}
    if fmt not in SUPPORTED:
        return fmt, "unsupported format or unreadable document", {}
    evidence: dict = {}
    if fmt in {"docx", "odt"}:
        try:
            with ZipFile(path) as archive:
                names = set(archive.namelist())
                if fmt == "docx":
                    root = ET.fromstring(archive.read("word/document.xml"))
                    tags = {node.tag.rsplit("}", 1)[-1] for node in root.iter()}
                    unsupported = {"tbl", "txbxContent", "drawing", "object", "altChunk", "hyperlink", "fldSimple", "instrText", "fldChar", "del", "moveFrom", "moveTo", "endnoteReference", "commentReference", "sym"}
                    if not include_footnotes:
                        unsupported.add("footnoteReference")
                    if tags & unsupported:
                        return fmt, "contains a table, link, field, revision, text box, drawing, or embedded object that plain extraction cannot represent fully", {}
                    if include_footnotes:
                        validate_footnotes(root, archive, names)
                    if any(node.find(WORD + "numPr") is not None for node in root.iter(WORD + "pPr")):
                        return fmt, "contains generated list numbering or bullets that plain extraction cannot represent", {}
                    if any(n.startswith("word/header") or n.startswith("word/footer") or
                           n in {"word/endnotes.xml", "word/comments.xml"} or
                           (n == "word/footnotes.xml" and not include_footnotes) for n in names):
                        for name in names:
                            if (name.startswith("word/header") or name.startswith("word/footer") or
                                    name in {"word/endnotes.xml", "word/comments.xml"} or
                                    (name == "word/footnotes.xml" and not include_footnotes)):
                                part = ET.fromstring(archive.read(name))
                                if meaningful_text(part):
                                    return fmt, "contains nonempty headers, footers, notes, or comments outside the extracted body", {}
                    styles = ET.fromstring(archive.read("word/styles.xml")) if "word/styles.xml" in names else None
                    evidence = title_style_evidence(root, styles, "docx")
                else:
                    root = ET.fromstring(archive.read("content.xml"))
                    tags = {node.tag.rsplit("}", 1)[-1] for node in root.iter()}
                    if tags & {"table", "table-row", "table-cell", "annotation", "tracked-changes", "text-box", "frame", "a", "list", "list-item", "list-header", "note", "note-body", "page-number", "page-count", "date", "time", "author-name", "user-defined", "database-display"}:
                        return fmt, "contains a table, link, frame, annotation, or tracked changes that plain extraction cannot represent fully", {}
                    if "styles.xml" in names:
                        styles_root = ET.fromstring(archive.read("styles.xml"))
                        for node in styles_root.iter():
                            if node.tag.rsplit("}", 1)[-1] in {"header", "footer"} and meaningful_text(node):
                                return fmt, "contains nonempty headers or footers outside the extracted body", {}
                    evidence = title_style_evidence(root, None, "odt")
        except (BadZipFile, KeyError, ET.ParseError, ValueError, OSError) as exc:
            return fmt, f"invalid document structure: {exc}", {}
    return fmt, None, evidence


def validate_footnotes(document: ET.Element, archive: ZipFile, names: set[str]) -> None:
    """Validate ordinary Word footnotes before opt-in text preservation."""
    reference_nodes = list(document.iter(WORD + "footnoteReference"))
    refs = []
    for node in reference_nodes:
        note_id = node.get(WORD + "id")
        if not note_id:
            raise ValueError("footnote reference has no id")
        if node.get(WORD + "customMarkFollows") in {"1", "true", "on"}:
            raise ValueError("custom footnote marks cannot be represented as numbered references")
        refs.append(note_id)
    if "word/footnotes.xml" not in names:
        if refs:
            raise ValueError("footnote references have no word/footnotes.xml part")
        return
    notes_root = ET.fromstring(archive.read("word/footnotes.xml"))
    notes: dict[str, ET.Element] = {}
    allowed = {"footnotes", "footnote", "p", "pPr", "pStyle", "ind", "spacing", "r", "rPr", "rStyle", "sz", "szCs", "vertAlign", "rtl", "i", "iCs", "b", "bCs", "t", "tab", "br", "cr", "noBreakHyphen", "softHyphen", "footnoteRef"}
    for note in notes_root.findall(WORD + "footnote"):
        note_id = note.get(WORD + "id")
        note_type = note.get(WORD + "type")
        if note_type in {"separator", "continuationSeparator"} or note_id in {"-1", "-2"}:
            continue
        if not note_id:
            raise ValueError("footnote has no id")
        for node in note.iter():
            if node.tag.rsplit("}", 1)[-1] not in allowed:
                raise ValueError("footnotes contain unsupported structures")
        if note_id in notes:
            raise ValueError("duplicate footnote id")
        notes[note_id] = note
    missing = sorted({ref for ref in refs if ref not in notes}, key=lambda value: value or "")
    if missing:
        raise ValueError("footnote references have no matching note: " + ", ".join(str(x) for x in missing))
    unreferenced = sorted(note_id for note_id, note in notes.items()
                          if note_id not in refs and meaningful_text(note))
    if unreferenced:
        raise ValueError("nonempty footnotes have no matching reference: " + ", ".join(unreferenced))


def title_style_evidence(root: ET.Element, styles: ET.Element | None, fmt: str) -> dict:
    """Count explicit title-style paragraphs; this is evidence only, not inference."""
    counts: dict[str, int] = {}
    locations = []
    if fmt == "docx":
        style_names: dict[str, str] = {}
        if styles is not None:
            for style in styles.findall(WORD + "style"):
                sid = style.get(WORD + "styleId", "")
                name = style.find(WORD + "name")
                style_names[sid] = name.get(WORD + "val", sid) if name is not None else sid
        for index, paragraph in enumerate(root.iter(WORD + "p")):
            ppr = paragraph.find(WORD + "pPr")
            pstyle = ppr.find(WORD + "pStyle") if ppr is not None else None
            if pstyle is not None:
                sid = pstyle.get(WORD + "val", "")
                name = style_names.get(sid, sid)
                if re.search(r"\btitle\b", name, re.I):
                    counts[name] = counts.get(name, 0) + 1
                    locations.append({"paragraph_index": index, "style": name})
    else:
        index = 0
        for paragraph in root.iter():
            if paragraph.tag not in {ODT_TEXT + "p", ODT_TEXT + "h"}:
                continue
            name = paragraph.get(ODT_TEXT + "style-name", "")
            if re.search(r"\btitle\b", name, re.I):
                counts[name] = counts.get(name, 0) + 1
                locations.append({"paragraph_index": index, "style": name})
            index += 1
    return {"explicit_title_style_paragraphs": counts,
            "explicit_title_style_locations": locations}


def discover(sources: list[Path], destination: Path, keep_format_on_collision: bool = False,
             include_footnotes: bool = False) -> list[dict]:
    rows = []
    for root in sources:
        if root.is_symlink():
            rows.append({"source": str(root), "status": "blocked", "reason": "source root is a symlink"})
            continue
        if not root.is_dir():
            rows.append({"source": str(root), "status": "blocked", "reason": "source folder unavailable"})
            continue
        for path in sorted(root.rglob("*")):
            if path.is_symlink():
                rows.append({"source": str(path), "relative": path.relative_to(root).as_posix(),
                             "status": "blocked", "reason": "symlink source entries are not followed"})
                continue
            if not path.is_file():
                continue
            rel = path.relative_to(root)
            if path.name == ".DS_Store" or path.suffix.lower() == ".zip":
                rows.append({"source": str(path), "relative": rel.as_posix(), "status": "skipped", "reason": "ancillary file"})
                continue
            if path.suffix.lower() == ".gdoc":
                rows.append({"source": str(path), "relative": rel.as_posix(), "status": "pending", "reason": ".gdoc reference requires an upstream readable copy"})
                continue
            fmt, reason, evidence = inspect(path, include_footnotes)
            if fmt is None and path.suffix.lower() == ".txt":
                fmt, reason = "txt", None
            elif fmt not in SUPPORTED:
                reason = reason or "unsupported file"
            output_name = path.stem + ".txt"
            output = destination / root.name / rel.parent / output_name
            output_symlink = symlink_component(absolute(output))
            if output_symlink:
                reason = f"output path contains symlink component: {output_symlink}"
            rows.append({"source": str(path), "relative": rel.as_posix(), "format": fmt,
                         "output": str(output), "status": "blocked" if reason else "ready",
                         "reason": reason, "evidence": evidence,
                         "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
    seen: dict[Path, dict] = {}
    for row in rows:
        if row.get("output"):
            output = Path(row["output"]).resolve()
            if output in seen:
                previous = seen[output]
                if keep_format_on_collision:
                    for conflicted in (previous, row):
                        suffix = Path(conflicted["source"]).suffix.lower()
                        conflicted["collision_output"] = conflicted["output"]
                        conflicted["output"] = str(Path(conflicted["output"]).with_name(
                            Path(conflicted["source"]).name + ".txt"))
                        conflicted["collision_resolution"] = f"retained source extension {suffix}"
                else:
                    row["status"] = previous["status"] = "blocked"
                    row["reason"] = previous["reason"] = "output name collision; resolve explicitly"
            else:
                seen[output] = row
    # A second collision after the explicit extension policy still needs a
    # human resolution; never choose between two same-format sources.
    final_outputs: dict[Path, dict] = {}
    for row in rows:
        if not row.get("output"):
            continue
        output = Path(row["output"]).resolve()
        if output in final_outputs:
            row["status"] = final_outputs[output]["status"] = "blocked"
            row["reason"] = final_outputs[output]["reason"] = "output name collision remains after format suffix; resolve explicitly"
        else:
            final_outputs[output] = row
    return rows


def docx_with_footnotes(path: Path, temp: Path) -> Path:
    """Build a scratch DOCX with inline markers and readable note paragraphs."""
    output = temp / (hashlib.sha256(path.read_bytes()).hexdigest() + "-footnotes.docx")
    with ZipFile(path) as source:
        names = set(source.namelist())
        document = ET.fromstring(source.read("word/document.xml"))
        validate_footnotes(document, source, names)
        note_root = ET.fromstring(source.read("word/footnotes.xml")) if "word/footnotes.xml" in names else None
        notes = {}
        if note_root is not None:
            notes = {note.get(WORD + "id"): note for note in note_root.findall(WORD + "footnote")
                     if note.get(WORD + "type") not in {"separator", "continuationSeparator"}
                     and note.get(WORD + "id") not in {"-1", "-2"}}
        for parent in document.iter():
            for index, child in enumerate(list(parent)):
                if child.tag != WORD + "footnoteReference":
                    continue
                marker = ET.Element(WORD + "t")
                marker.text = f"[{child.get(WORD + 'id')}]"
                marker.tail = child.tail
                parent.remove(child)
                parent.insert(index, marker)
        body = document.find(f"{WORD}body")
        if notes and body is None:
            raise ValueError("document has no body for footnote text")
        if body is not None:
            for ref in dict.fromkeys(node.get(WORD + "id") for node in ET.fromstring(source.read("word/document.xml")).iter(WORD + "footnoteReference")):
                note = notes[ref]
                paragraphs = note.findall(WORD + "p")
                if not paragraphs:
                    raise ValueError(f"footnote {ref} has no readable paragraph")
                for paragraph in paragraphs:
                    copied = ET.fromstring(ET.tostring(paragraph, encoding="unicode"))
                    for parent in copied.iter():
                        for child in list(parent):
                            if child.tag == WORD + "footnoteRef":
                                parent.remove(child)
                    runs = copied.findall(WORD + "r")
                    if runs:
                        first_text = runs[0].find(WORD + "t")
                        if first_text is None:
                            first_text = ET.Element(WORD + "t")
                            runs[0].insert(0, first_text)
                        first_text.text = f"[{ref}] " + (first_text.text or "")
                    else:
                        run = ET.SubElement(copied, WORD + "r")
                        ET.SubElement(run, WORD + "t").text = f"[{ref}] "
                    body.append(copied)
        with ZipFile(output, "w") as target:
            for item in source.infolist():
                data = ET.tostring(document, encoding="utf-8", xml_declaration=True) if item.filename == "word/document.xml" else source.read(item.filename)
                target.writestr(item, data)
    return output


def extract_content(row: dict, temp: Path, include_footnotes: bool = False) -> tuple[bytes, dict]:
    source = Path(row["source"])
    fmt = row["format"]
    if fmt == "txt":
        data = source.read_bytes()
        data.decode("utf-8")
        return data, {}
    if fmt == "doc":
        converted = temp / (hashlib.sha256(source.read_bytes()).hexdigest() + ".docx")
        subprocess.run(["textutil", "-convert", "docx", "-format", "doc", "-output", str(converted), str(source)], check=True, capture_output=True)
        converted_fmt, reason, evidence = inspect(converted)
        if converted_fmt != "docx" or reason:
            raise ValueError("textutil DOC conversion produced unsupported content: " + (reason or str(converted_fmt)))
        paragraphs = read_docx(converted)
    elif fmt == "docx":
        prepared = docx_with_footnotes(source, temp) if include_footnotes else source
        paragraphs = read_docx(prepared)
        _, _, evidence = inspect(source, include_footnotes)
    elif fmt == "odt":
        paragraphs = read_odt(source)
        _, _, evidence = inspect(source)
    else:
        raise ValueError("unsupported format")
    return "\n".join(paragraphs).encode("utf-8"), evidence


def run(sources: list[Path], destination: Path, write: bool = False,
        allow_pending: bool = False, keep_format_on_collision: bool = False,
        deduplicate_identical: bool = False, include_footnotes: bool = False) -> dict:
    sources, destination = validate_paths(sources, destination)
    rows = discover(sources, destination, keep_format_on_collision or deduplicate_identical, include_footnotes)
    report = {"destination": str(destination), "files": rows}
    # Extraction preflight applies equally to plan and write modes. Everything is
    # materialized in temporary storage before the destination is touched.
    with tempfile.TemporaryDirectory(prefix="still-text-preflight-") as scratch:
        scratch_path = Path(scratch)
        staged: list[tuple[dict, Path]] = []
        for i, row in enumerate(rows):
            if row["status"] != "ready":
                continue
            try:
                source = Path(row["source"])
                data, evidence = extract_content(row, scratch_path, include_footnotes)
                row["evidence"] = evidence
                if hashlib.sha256(source.read_bytes()).hexdigest() != row["sha256"]:
                    raise RuntimeError("source changed during preflight")
                staged_file = scratch_path / f"prepared-{i}"
                staged_file.write_bytes(data)
                row["output_sha256"] = hashlib.sha256(data).hexdigest()
                staged.append((row, staged_file))
            except Exception as exc:
                row["status"] = "blocked"
                row["reason"] = f"preflight extraction failed: {exc}"
        if deduplicate_identical:
            groups: dict[str, list[tuple[dict, Path]]] = {}
            for item in staged:
                row, _ = item
                original_collision_output = row.get("collision_output")
                if original_collision_output:
                    groups.setdefault(str(Path(original_collision_output).resolve()), []).append(item)
            duplicates = set()
            for original_output, group in groups.items():
                if len(group) < 2:
                    continue
                first_row, first_file = group[0]
                first_bytes = first_file.read_bytes()
                if all(staged_file.read_bytes() == first_bytes for _, staged_file in group[1:]):
                    first_row["output"] = original_output
                    first_row["collision_resolution"] = "identical extracted bytes; retained one output"
                    for duplicate_row, _ in group[1:]:
                        duplicate_row["status"] = "duplicate"
                        duplicate_row["duplicate_of"] = {"source": first_row["source"], "output": original_output}
                        duplicate_row["output"] = None
                        duplicate_row["collision_resolution"] = "identical extracted bytes; recorded as duplicate"
                        duplicates.add(id(duplicate_row))
            staged = [(row, path) for row, path in staged if id(row) not in duplicates]
        report["counts"] = {s: sum(r["status"] == s for r in rows)
                             for s in ("ready", "pending", "blocked", "skipped", "duplicate")}
        report["duplicate_count"] = report["counts"]["duplicate"]
        title_styles: dict[str, int] = {}
        for row in rows:
            if row.get("status") == "ready":
                for style, count in row.get("evidence", {}).get("explicit_title_style_paragraphs", {}).items():
                    title_styles[style] = title_styles.get(style, 0) + count
        report["explicit_title_style_paragraphs"] = title_styles
        if not write:
            return report
        if report["counts"]["blocked"] or (report["counts"]["pending"] and not allow_pending):
            raise ValueError("plan contains blocked files or pending .gdoc references; review and resolve before writing")
        for row, _ in staged:
            if Path(row["output"]).exists():
                raise FileExistsError(f"refusing to overwrite: {row['output']}")
        destination.parent.mkdir(parents=True, exist_ok=True)
        # Temp files are on the destination filesystem. os.link is atomic and
        # fails if a target exists, unlike rename/replace which can overwrite.
        with tempfile.TemporaryDirectory(prefix="still-text-stage-", dir=destination.parent) as publish_dir:
            publish_stage = Path(publish_dir)
            publish_items = []
            for i, (row, source_stage) in enumerate(staged):
                staged_copy = publish_stage / str(i)
                shutil.copyfile(source_stage, staged_copy)
                publish_items.append((staged_copy, Path(row["output"])))
            destination.mkdir(parents=True, exist_ok=True)
            published: list[Path] = []
            try:
                for staged_copy, output in publish_items:
                    output.parent.mkdir(parents=True, exist_ok=True)
                    os.link(staged_copy, output)
                    published.append(output)
                for row, _ in staged:
                    source = Path(row["source"])
                    if hashlib.sha256(source.read_bytes()).hexdigest() != row["sha256"]:
                        raise RuntimeError(f"source changed during publish: {source}")
            except Exception:
                for output in published:
                    output.unlink(missing_ok=True)
                raise
        report["written"] = len(staged)
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", action="append", type=Path, required=True,
                        help="approved local source root (repeat for each notebook tree)")
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--write", action="store_true", help="execute the reviewed plan")
    parser.add_argument("--allow-pending", action="store_true", help="permit pending .gdoc references during partial conversion")
    parser.add_argument("--keep-format-on-collision", action="store_true",
                        help="resolve same-stem files as name.docx.txt/name.odt.txt instead of blocking")
    parser.add_argument("--deduplicate-identical", action="store_true",
                        help="for same-folder same-stem collisions, keep one file only when extracted bytes match exactly")
    parser.add_argument("--include-footnotes", action="store_true",
                        help="preserve DOCX footnote references inline and append their text (opt-in)")
    args = parser.parse_args()
    try:
        report = run(args.source, args.destination, args.write, args.allow_pending,
                     args.keep_format_on_collision, args.deduplicate_identical, args.include_footnotes)
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    print(json.dumps(report, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
