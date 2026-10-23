#!/usr/bin/env python3
"""Prepare Still's local Lists import without changing the selected source folder.

DOC is read by macOS's Word importer, then its DOCX structure is read just like
native DOCX. ODT is read directly. These formats store authored breaks separately
from page-width wrapping; only the former become newlines here.

    python3 scripts/import_lists.py --source /path/to/source-lists --output data/lists.json
    python3 -m unittest discover -s scripts -p 'test_*.py'
"""

from __future__ import annotations

import argparse
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from difflib import SequenceMatcher
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile
import unicodedata
from xml.etree import ElementTree as ET
from zipfile import BadZipFile, ZipFile


W = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"
TEXT = "{urn:oasis:names:tc:opendocument:xmlns:text:1.0}"
STYLE = "{urn:oasis:names:tc:opendocument:xmlns:style:1.0}"
FO = "{urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0}"
OFFICE = "{urn:oasis:names:tc:opendocument:xmlns:office:1.0}"
OLE = bytes.fromhex("d0cf11e0a1b11ae1")


@dataclass
class Artifact:
    path: Path
    relative_path: str
    format: str
    sha256: str
    paragraphs: list[str]


def identify_format(path: Path) -> str | None:
    """Trust a file's contents, including extensionless and mislabeled files."""
    with path.open("rb") as stream:
        signature = stream.read(8)
    if signature == OLE:
        return "doc"
    if signature.startswith(b"PK"):
        try:
            with ZipFile(path) as archive:
                names = set(archive.namelist())
                if "word/document.xml" in names:
                    return "docx"
                if "content.xml" in names and "mimetype" in names:
                    if archive.read("mimetype") == b"application/vnd.oasis.opendocument.text":
                        return "odt"
        except BadZipFile:
            pass
    return None


def indentation(twips: int) -> str:
    """Half-inch Word indents become tabs; smaller offsets retain their depth."""
    twips = max(0, twips)
    tabs, remainder = divmod(twips, 720)
    return "\t" * tabs + " " * round(remainder / 90)


def word_text(element: ET.Element) -> str:
    if element.tag in {W + "del", W + "moveFrom"}:
        return ""
    if element.tag == W + "t":
        return element.text or ""
    if element.tag == W + "tab":
        return "\t"
    if element.tag in {W + "br", W + "cr"}:
        return "\n"
    if element.tag == W + "noBreakHyphen":
        return "\u2011"
    if element.tag == W + "softHyphen":
        return "\u00ad"
    return "".join(word_text(child) for child in element)


def word_indents(properties: ET.Element | None) -> dict[str, int]:
    if properties is None:
        return {}
    ind = properties.find(W + "ind")
    if ind is None:
        return {}
    names = {"start": "left", "left": "left", "firstLine": "first",
             "first-line": "first", "hanging": "hanging"}
    return {names[key.removeprefix(W)]: int(value)
            for key, value in ind.attrib.items() if key.removeprefix(W) in names}


def read_docx(path: Path) -> list[str]:
    with ZipFile(path) as archive:
        document = ET.fromstring(archive.read("word/document.xml"))
        styles = {}
        defaults = {}
        if "word/styles.xml" in archive.namelist():
            style_root = ET.fromstring(archive.read("word/styles.xml"))
            defaults = word_indents(style_root.find(f"{W}docDefaults/{W}pPrDefault/{W}pPr"))
            for style in style_root.findall(W + "style"):
                based_on = style.find(W + "basedOn")
                styles[style.get(W + "styleId")] = (
                    based_on.get(W + "val") if based_on is not None else None,
                    word_indents(style.find(W + "pPr")),
                )

        def inherited(name, seen=None):
            seen = set() if seen is None else seen
            if name not in styles or name in seen:
                return dict(defaults)
            seen.add(name)
            parent, values = styles[name]
            return inherited(parent, seen) | values

        paragraphs = []
        body = document.find(W + "body")
        for paragraph in body.iter(W + "p"):
            text = word_text(paragraph)
            properties = paragraph.find(W + "pPr")
            pstyle = properties.find(W + "pStyle") if properties is not None else None
            values = inherited(pstyle.get(W + "val") if pstyle is not None else "Normal")
            values.update(word_indents(properties))
            left = values.get("left", 0)
            first = left + values.get("first", 0) - values.get("hanging", 0)
            lines = text.split("\n")
            paragraphs.append("\n".join(
                indentation(first if index == 0 else left) + line if line else ""
                for index, line in enumerate(lines)
            ))
        return paragraphs


def odt_text(element: ET.Element) -> str:
    if element.tag in {OFFICE + "annotation", TEXT + "tracked-changes"}:
        return ""
    if element.tag == TEXT + "s":
        return " " * int(element.get(TEXT + "c", "1"))
    if element.tag == TEXT + "tab":
        return "\t"
    if element.tag == TEXT + "line-break":
        return "\n"
    text = element.text or ""
    for child in element:
        text += odt_text(child) + (child.tail or "")
    return text


def length_twips(value: str) -> int:
    match = re.fullmatch(r"(-?[\d.]+)(in|cm|mm|pt)", value)
    if not match:
        return 0
    number, unit = match.groups()
    factor = {"in": 1440, "cm": 1440 / 2.54, "mm": 1440 / 25.4, "pt": 20}[unit]
    return round(float(number) * factor)


def read_odt(path: Path) -> list[str]:
    with ZipFile(path) as archive:
        document = ET.fromstring(archive.read("content.xml"))
        style_documents = [document]
        if "styles.xml" in archive.namelist():
            style_documents.insert(0, ET.fromstring(archive.read("styles.xml")))
        styles = {}
        for style_document in style_documents:
            for style in style_document.iter(STYLE + "style"):
                properties = style.find(STYLE + "paragraph-properties")
                values = {} if properties is None else {
                    key.removeprefix(FO): length_twips(value)
                    for key, value in properties.attrib.items()
                    if key in {FO + "margin-left", FO + "text-indent"}
                }
                styles[style.get(STYLE + "name")] = (style.get(STYLE + "parent-style-name"), values)

        def inherited(name, seen=None):
            seen = set() if seen is None else seen
            if name not in styles or name in seen:
                return {}
            seen.add(name)
            parent, values = styles[name]
            return inherited(parent, seen) | values

        paragraphs = []
        body = document.find(f"{OFFICE}body/{OFFICE}text")
        for paragraph in body.iter():
            if paragraph.tag not in {TEXT + "p", TEXT + "h"}:
                continue
            text = odt_text(paragraph)
            values = inherited(paragraph.get(TEXT + "style-name"))
            left = values.get("margin-left", 0)
            first = left + values.get("text-indent", 0)
            paragraphs.append("\n".join(
                indentation(first if index == 0 else left) + line if line else ""
                for index, line in enumerate(text.split("\n"))
            ))
        return paragraphs


def extract(path: Path, root: Path, format: str, temporary: Path) -> Artifact:
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if format == "doc":
        path_key = hashlib.sha256(str(path).encode()).hexdigest()[:12]
        converted = temporary / (digest + "-" + path_key + ".docx")
        subprocess.run(["textutil", "-convert", "docx", "-format", "doc", "-output",
                        str(converted), str(path)], check=True, capture_output=True)
        paragraphs = read_docx(converted)
    else:
        paragraphs = (read_docx if format == "docx" else read_odt)(path)
    return Artifact(path, path.relative_to(root).as_posix(), format, digest, paragraphs)


def is_colon_title(value: str) -> bool:
    # Entire titled paragraphs, including historical "Title: or Other:Title:".
    value = value.strip()
    return (value.endswith(":")
            and (value.count(":") >= 2 or bool(re.fullmatch(r"[\w’']+:", value)))
            and not value.startswith(("-", '"', "“", "("))
            and bool(re.fullmatch(r"[\w’'’:!?.,–— -]+", value, re.UNICODE)))


def colon_title(value: str) -> str:
    value = value.replace("'", "").replace("’", "")
    words = re.findall(r"[^\W_]+", value, re.UNICODE)
    return ":".join(word.title() for word in words) + ":"


def filename_title(path: Path) -> str:
    name = path.stem if path.suffix.lower() in {".doc", ".docx", ".odt", ".txt"} else path.name
    return re.sub(r"^\d+[. ]*", "", name).replace("_", " ").replace(".", " ").strip()


def opening_title(first: str, path: Path) -> str:
    name = filename_title(path)
    opening_words = colon_title(first).lower().split(":")[:-1]
    name_words = colon_title(name).lower().split(":")[:-1]
    # Use the authored wording when an opening supplies the filename's title.
    # A name that continues after the opening can combine two opening lines.
    if name_words[:len(opening_words)] == opening_words and len(name_words) > len(opening_words):
        return name
    if len(opening_words) >= 4 and SequenceMatcher(None, opening_words, name_words).ratio() >= 0.8:
        return first
    return name


def remove_structural_dashes(body: str, marker_convention: bool = False) -> str:
    lines = body.split("\n")
    # Older files often omit the space after the handwritten section marker.
    # Multiple markers at section starts establish that local convention.
    dense = marker_convention or sum(bool(re.match(r"^[ \t]*-(?=\S)", line)) for line in lines) >= 3
    result = []
    for line in lines:
        line = re.sub(r"^([ \t]*)- +(?=\S)", r"\1", line)
        if dense:
            line = re.sub(r"^([ \t]*)-(?=[^\W\d_]|[“\"'(])", r"\1", line)
        result.append(line)
    return "\n".join(result)


def trim_blank_paragraphs(paragraphs: list[str]) -> list[str]:
    paragraphs = list(paragraphs)
    while paragraphs and not paragraphs[0].strip():
        paragraphs.pop(0)
    while paragraphs and not paragraphs[-1].strip():
        paragraphs.pop()
    return paragraphs


def split_pieces(artifact: Artifact) -> list[dict]:
    # A few recent documents keep the entire List in one paragraph, with manual
    # line breaks. Those breaks are just as authored as paragraph boundaries.
    paragraphs = "\n".join(artifact.paragraphs).split("\n")
    titles = [index for index, text in enumerate(paragraphs) if is_colon_title(text)]
    if titles:
        preamble = "\n".join(trim_blank_paragraphs(paragraphs[:titles[0]]))
        pieces = []
        for order, start in enumerate(titles):
            end = titles[order + 1] if order + 1 < len(titles) else len(paragraphs)
            original = "\n".join(trim_blank_paragraphs(paragraphs[start + 1:end]))
            pieces.append({"title": paragraphs[start].strip(), "original_title": paragraphs[start],
                           "original_body": original, "preamble": preamble if order == 0 else "",
                           "title_origin": "document", "source_order": order})
        return pieces

    nonblank = next((index for index, text in enumerate(paragraphs) if text.strip()), None)
    if nonblank is None:
        raise ValueError("Document contains no writing")
    first = paragraphs[nonblank]
    separated = nonblank + 1 < len(paragraphs) and not paragraphs[nonblank + 1].strip()
    # In experimental verse the first line can also supply its name. Keep that
    # line in the writing; filenames sometimes supply two opening lines as title.
    original = "\n".join(trim_blank_paragraphs(paragraphs[nonblank + 1 if separated else nonblank:]))
    return [{"title": colon_title(first if separated else opening_title(first, artifact.path)),
             "original_title": first, "original_body": original, "preamble": "",
             "title_origin": "document" if separated else "filename", "source_order": 0}]


def normalized_content(artifact: Artifact) -> str:
    return "\n".join(re.sub(r"\s+", " ", line).strip()
                     for line in trim_blank_paragraphs("\n".join(artifact.paragraphs).split("\n")))


def artifact_number(path: Path) -> str:
    match = re.match(r"^(\d+)", path.name)
    return match.group(1) if match else path.stem


def source_group(artifact: Artifact) -> str:
    stem = artifact.path.stem if artifact.path.suffix.lower() in {".doc", ".docx", ".odt", ".txt"} else artifact.path.name
    stem = unicodedata.normalize("NFC", stem).lower()
    stem = re.sub(r"[^\w]+", "-", stem.replace("_", "-")).strip("-")
    return (Path(artifact.relative_path).parent / stem).as_posix()


def make_manifest(root: Path) -> dict:
    candidates, skipped = [], []
    for path in sorted(p for p in root.rglob("*") if p.is_file()):
        relative = path.relative_to(root).as_posix()
        format = identify_format(path)
        if "list-format-samples" in path.parts or format is None:
            skipped.append({"path": relative, "reason": "format sample" if "list-format-samples" in path.parts else "not a writing document"})
        else:
            candidates.append((path, format))
    with tempfile.TemporaryDirectory(prefix="still-lists-") as directory:
        def read(candidate):
            path, format = candidate
            return extract(path, root, format, Path(directory))
        with ThreadPoolExecutor(max_workers=4) as workers:
            artifacts = list(workers.map(read, candidates))

    # Only alternate formats of the same numbered artifact within one notebook
    # can merge. Identical text elsewhere remains separate writing.
    nearby = defaultdict(list)
    groups = []
    for artifact in artifacts:
        key = (str(Path(artifact.relative_path).parent), artifact_number(artifact.path), normalized_content(artifact))
        group = next((group for group in nearby[key]
                      if all(other.format != artifact.format or other.sha256 == artifact.sha256
                             for other in group)), None)
        if group is None:
            group = []
            nearby[key].append(group)
            groups.append(group)
        group.append(artifact)

    def preference(artifact):
        return ({"odt": 0, "docx": 1, "doc": 2}[artifact.format], artifact.relative_path)

    def neighborhood_order(alternatives):
        preferred = min(alternatives, key=preference)
        number = artifact_number(preferred.path)
        return (str(Path(preferred.relative_path).parent), int(number) if number.isdigit() else 10**9,
                preferred.relative_path)

    entries, sources = [], []
    notebook_positions = Counter()
    for alternatives in sorted(groups, key=neighborhood_order):
        # ODT is the directly authored source where Word was a later conversion.
        preferred = min(alternatives, key=preference)
        notebook = str(Path(preferred.relative_path).parent)
        artifact_order = notebook_positions[notebook]
        notebook_positions[notebook] += 1
        group_key = source_group(preferred)
        artifacts_metadata = [{"path": a.relative_path, "sha256": a.sha256, "format": a.format} for a in alternatives]
        sources.append({"source_group": group_key, "artifacts": artifacts_metadata,
                        "extracted_text": "\n".join(preferred.paragraphs)})
        marker_convention = (preferred.format == "doc" and preferred.relative_path.startswith("Early Notebooks/")) or (
            sum(bool(re.match(r"^[ \t]*-(?=\S)", line))
                for line in "\n".join(preferred.paragraphs).split("\n")) >= 3
        )
        for piece in split_pieces(preferred):
            body = remove_structural_dashes(piece["original_body"], marker_convention)
            if not body.strip():
                raise ValueError(f"Empty List after title: {preferred.relative_path}: {piece['title']}")
            entries.append({"title": piece["title"], "body": body,
                            "source_key": "lists:" + hashlib.sha256(f"{group_key}#{piece['source_order']}".encode()).hexdigest(),
                            "source_group": group_key,
                            "notebook": notebook,
                            "source_order": artifact_order * 100 + piece["source_order"],
                            "source": {"original_title": piece["original_title"],
                                       "preamble": piece["preamble"], "original_body": piece["original_body"],
                                       "title_origin": piece["title_origin"], "artifacts": artifacts_metadata,
                                       "artifact_order": artifact_order, "piece_order": piece["source_order"]}})
    return {"format": "still-lists-1", "entries": entries, "sources": sources,
            "report": {"source_artifacts": len(artifacts), "source_groups": len(groups),
                       "lists": len(entries), "alternate_artifacts_merged": len(artifacts) - len(groups),
                       "formats": dict(Counter(a.format for a in artifacts)),
                       "notebooks": dict(Counter(entry["notebook"] for entry in entries)),
                       "sibling_groups": sum(len(split_pieces(group[0])) > 1 for group in groups),
                       "preambles": sum(bool(entry["source"]["preamble"]) for entry in entries),
                       "opening_lines_retained": sum(entry["source"]["title_origin"] == "filename" for entry in entries),
                       "skipped": skipped}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True, help="Folder of source documents (read-only)")
    parser.add_argument("--output", type=Path, default=Path("data/lists.json"))
    args = parser.parse_args()
    manifest = make_manifest(args.source.expanduser().resolve())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=args.output.parent, delete=False) as stream:
        json.dump(manifest, stream, ensure_ascii=False, indent=2)
        stream.write("\n")
        temporary = Path(stream.name)
    temporary.replace(args.output)
    print(json.dumps(manifest["report"], indent=2))


if __name__ == "__main__":
    main()
