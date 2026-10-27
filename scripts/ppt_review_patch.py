"""Patch one exact PowerPoint text run; preserve every other package part."""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
import zipfile

from lxml import etree
from pptx import Presentation
from inspect_document import guard_ooxml, SENSITIVE_RULES


NS = {"p": "http://schemas.openxmlformats.org/presentationml/2006/main",
      "a": "http://schemas.openxmlformats.org/drawingml/2006/main"}


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest().upper()


def private_patterns(text: str) -> list[str]:
    hits = [label for label, rule in SENSITIVE_RULES if rule.search(text)]
    if re.search(r"(?i)(?:password|passwd|token|cookie|api[_-]?key|secret)\s*[:=]\s*\S+", text):
        hits.append("credential-assignment")
    return hits


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("--slide", type=int, required=True)
    parser.add_argument("--old", required=True)
    parser.add_argument("--new", required=True)
    parser.add_argument("--expected-sha256", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.source.suffix.lower() != ".pptx" or args.output.suffix.lower() != ".pptx":
        raise ValueError("Only PPTX source and output are accepted")
    if args.output.exists() or args.source.resolve() == args.output.resolve():
        raise ValueError("Output must be a new file; original cannot be overwritten")
    if not args.old or not args.new or args.old == args.new or len(args.new) > 500:
        raise ValueError("An actual text change of 1 to 500 characters is required")
    if private_patterns(args.new):
        raise ValueError("Replacement contains sensitive patterns; no output prepared")
    source_hash = digest(args.source)
    if source_hash != args.expected_sha256.upper():
        raise ValueError("Reviewed version is stale: source hash no longer matches")
    guard_ooxml(args.source)
    presentation = Presentation(str(args.source))
    if not 1 <= args.slide <= len(presentation.slides):
        raise ValueError("Slide number is out of range")
    slide = presentation.slides[args.slide - 1]
    # Part names come from presentation order, not a guessed slideN.xml filename.
    part_name = str(slide.part.partname).lstrip("/")
    before_geometry = [(s.shape_id, s.left, s.top, s.width, s.height) for s in slide.shapes]
    all_text = "\n".join(s.text for s in slide.shapes if s.has_text_frame)
    if private_patterns(all_text):
        raise ValueError("Selected slide contains sensitive patterns; manual handling required")

    xml_parser = etree.XMLParser(resolve_entities=False, no_network=True, huge_tree=False)
    with zipfile.ZipFile(args.source) as archive:
        root = etree.fromstring(archive.read(part_name), parser=xml_parser)
        matches = [n for n in root.xpath("//p:sp/p:txBody//a:t", namespaces=NS) if n.text == args.old]
        if len(matches) != 1:
            raise ValueError("Old text must match exactly one plain text run; ambiguous or split runs require clarification")
        matches[0].text = args.new
        replacement = etree.tostring(root, encoding="UTF-8", xml_declaration=True, standalone=True)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        fd, temporary_name = tempfile.mkstemp(prefix="ppt-review-", suffix=".pptx", dir=args.output.parent)
        os.close(fd)
        temporary = Path(temporary_name)
        try:
            with zipfile.ZipFile(temporary, "w") as target:
                for info in archive.infolist():
                    payload = replacement if info.filename == part_name else archive.read(info.filename)
                    # ZipFile rewrites header offsets on the supplied ZipInfo.
                    # Keep the source archive's metadata intact for later reads.
                    target.writestr(copy.copy(info), payload)
            with zipfile.ZipFile(temporary) as check:
                if check.testzip() is not None:
                    raise ValueError("Output archive failed CRC validation")
                if check.namelist() != archive.namelist():
                    raise ValueError("Package members changed unexpectedly")
                untouched = 0
                for name in archive.namelist():
                    if name != part_name:
                        if check.read(name) != archive.read(name):
                            raise ValueError("An unrelated package part changed")
                        untouched += 1
            updated = Presentation(str(temporary))
            updated_slide = updated.slides[args.slide - 1]
            after_geometry = [(s.shape_id, s.left, s.top, s.width, s.height) for s in updated_slide.shapes]
            if len(updated.slides) != len(presentation.slides) or before_geometry != after_geometry:
                raise ValueError("Slide count or shape geometry changed")
            updated_text = "\n".join(s.text for s in updated_slide.shapes if s.has_text_frame)
            if args.new not in updated_text or digest(args.source) != source_hash:
                raise ValueError("Text verification or original-file hash check failed")
            # Rename is exclusive: refuse even if another writer created output meanwhile.
            temporary.rename(args.output)
            print(json.dumps({"status": "patched", "slideNumber": args.slide,
                              "slideCount": len(updated.slides), "sourceSha256": source_hash,
                              "outputSha256": digest(args.output), "outputPath": str(args.output),
                              "unchangedPackageParts": untouched, "geometryUnchanged": True,
                              "originalUnchanged": True, "visualQa": "not-rendered"}, ensure_ascii=False))
        finally:
            if temporary.exists():
                temporary.unlink()


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(json.dumps({"status": "rejected", "error": str(exc)}, ensure_ascii=False))
        raise SystemExit(1)
