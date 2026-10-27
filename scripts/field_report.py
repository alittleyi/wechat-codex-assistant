"""Explicit project requirements + reported field observations -> review PDF copy.

This is a renderer, not an image recognizer or an acceptance decision maker.
The caller must review text and images for contextual privacy before invoking it.
"""
import argparse
import hashlib
import json
import re
from pathlib import Path
from xml.sax.saxutils import escape

from PIL import Image as PILImage
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.lib import colors
from reportlab.lib.styles import ParagraphStyle
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Image, KeepTogether


class Rejected(ValueError):
    pass


def digest(data):
    return hashlib.sha256(data).hexdigest()


def safe_text(value, maximum=800):
    if not isinstance(value, str) or not value.strip() or len(value) > maximum:
        raise Rejected("Invalid or oversized text field.")
    # Conservative first gate. Contextual addresses, names and screenshots still
    # require manual review; these patterns are NOT a privacy guarantee.
    patterns = [r"(?<!\d)1[3-9]\d{9}(?!\d)", r"(?<!\d)\d{17}[\dXx](?!\w)",
                r"(?<!\d)\d{13,19}(?!\d)", r"[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}",
                r"(?i)(cookie|context.?token|api.?key|password|access.?token|身份证|手机号|住址|账号)\s*[:：=]",
                r"[\x00-\x08\x0b\x0c\x0e-\x1f]"]
    if any(re.search(pattern, value) for pattern in patterns):
        raise Rejected("Sensitive patterns detected; use manually redacted inputs.")
    return value.strip()


def load_input(path, expected):
    if path.suffix.lower() != ".json" or path.stat().st_size > 100 * 1024:
        raise Rejected("Only JSON inputs up to 100 KiB are accepted.")
    raw = path.read_bytes()
    if digest(raw).lower() != expected.lower():
        raise Rejected("Source revision changed.")
    value = json.loads(raw.decode("utf-8-sig"))
    if not isinstance(value, dict):
        raise Rejected("Input must be an object.")
    return value, raw


def validate_observations(value, baseline_hash, indexed, photo_ids=None):
    if not isinstance(value.get("baselineSha256"), str) or value["baselineSha256"].lower() != baseline_hash.lower():
        raise Rejected("Observations refer to a different baseline.")
    entries = value.get("entries")
    if not isinstance(entries, list) or len(entries) > 30:
        raise Rejected("Expected at most 30 observations.")
    mapped = {}
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != {"requirementId", "observation", "reportedResult", "evidenceIds"}:
            raise Rejected("Observation schema mismatch.")
        key = entry["requirementId"]
        if key not in indexed or key in mapped:
            raise Rejected("Unknown or duplicate observation target.")
        if entry["reportedResult"] not in {"match", "gap", "unverified"}:
            raise Rejected("Invalid reported result.")
        ids = entry["evidenceIds"]
        if not isinstance(ids, list) or any(not isinstance(i, str) or not re.fullmatch(r"E[1-6]", i) for i in ids) or len(ids) != len(set(ids)):
            raise Rejected("Invalid evidence mapping.")
        if photo_ids is not None and any(i not in photo_ids for i in ids):
            raise Rejected("Missing evidence.")
        mapped[key] = {**entry, "observation": safe_text(entry["observation"])}
    return mapped


def build(args):
    baseline_path, observation_path = Path(args.baseline), Path(args.observations)
    baseline, baseline_bytes = load_input(baseline_path, args.baseline_sha256)
    observations, observation_bytes = load_input(observation_path, args.observations_sha256)
    title = safe_text(baseline.get("title"), 100)
    requirements = baseline.get("requirements")
    if not isinstance(requirements, list) or not 1 <= len(requirements) <= 30:
        raise Rejected("Expected 1 to 30 requirements.")
    indexed = {}
    for requirement in requirements:
        if not isinstance(requirement, dict) or set(requirement) != {"id", "expected"}:
            raise Rejected("Requirement schema mismatch.")
        key = requirement["id"]
        if not isinstance(key, str) or not re.fullmatch(r"[A-Z][A-Z0-9-]{0,15}", key) or key in indexed:
            raise Rejected("Requirement IDs must be unique ASCII identifiers.")
        indexed[key] = safe_text(requirement["expected"])

    photos = []
    if len(args.evidence) > 6:
        raise Rejected("At most six evidence photos are accepted.")
    total = 0
    for number, name in enumerate(args.evidence, 1):
        path = Path(name)
        if path.suffix.lower() not in {".jpg", ".jpeg", ".png"}:
            raise Rejected("Only PNG and JPEG evidence is accepted.")
        raw = path.read_bytes()
        total += len(raw)
        if len(raw) > 5 * 1024 * 1024 or total > 15 * 1024 * 1024:
            raise Rejected("Evidence photo size limit exceeded.")
        with PILImage.open(path) as picture:
            if picture.format not in {"JPEG", "PNG"} or picture.width * picture.height > 16_000_000:
                raise Rejected("Evidence format or pixel limit exceeded.")
            picture.verify()
        photos.append({"id": "E" + str(number), "path": path, "sha256": digest(raw)})
    photo_ids = {photo["id"] for photo in photos}
    mapped = validate_observations(observations, args.baseline_sha256, indexed, photo_ids)
    if photo_ids != {i for entry in mapped.values() for i in entry["evidenceIds"]}:
        raise Rejected("Unmapped evidence needs a project association first.")

    previous_path = getattr(args, "previous_observations", None)
    previous_hash = getattr(args, "previous_observations_sha256", None)
    if bool(previous_path) != bool(previous_hash):
        raise Rejected("Previous observation path and expected revision hash must be supplied together.")
    changes = []
    evidence_changes = []
    previous_bytes = None
    previous_manifest_path = getattr(args, "previous_evidence_manifest", None)
    previous_manifest_hash = getattr(args, "previous_evidence_manifest_sha256", None)
    previous_manifest_bytes = None
    previous_report_path = None
    previous_report_hash = None
    if bool(previous_manifest_path) != bool(previous_manifest_hash) or (previous_manifest_path and not previous_path):
        raise Rejected("Previous evidence manifest needs its revision hash and previous observations.")
    state_labels = {"match": "用户报告一致", "gap": "用户报告差异", "unverified": "尚未核实"}
    if previous_path:
        previous_path = Path(previous_path)
        previous, previous_bytes = load_input(previous_path, previous_hash)
        older = validate_observations(previous, args.baseline_sha256, indexed)
        if set(older) - set(mapped):
            raise Rejected("Supplement must preserve previous observations; clarify missing items.")
        if any(e["evidenceIds"] for e in older.values()) or photos:
            if not previous_manifest_path:
                raise Rejected("Photo-bearing revisions need the previous evidence manifest.")
        if previous_manifest_path:
            previous_manifest_path = Path(previous_manifest_path)
            manifest, previous_manifest_bytes = load_input(previous_manifest_path, previous_manifest_hash)
            if set(manifest) != {"schemaVersion", "baselineSha256", "observationsSha256", "reportSha256", "evidence"} or manifest["schemaVersion"] != 1:
                raise Rejected("Previous evidence manifest schema mismatch.")
            if manifest["baselineSha256"].lower() != args.baseline_sha256.lower() or manifest["observationsSha256"].lower() != previous_hash.lower():
                raise Rejected("Previous evidence manifest refers to another revision.")
            previous_report_path = previous_manifest_path.with_suffix(".pdf")
            previous_report_hash = manifest["reportSha256"]
            if not re.fullmatch(r"[a-fA-F0-9]{64}", previous_report_hash) or digest(previous_report_path.read_bytes()) != previous_report_hash:
                raise Rejected("Previous report changed or is unavailable.")
            old_photos = {}
            if not isinstance(manifest["evidence"], list) or len(manifest["evidence"]) > 6:
                raise Rejected("Invalid previous photo manifest.")
            for item in manifest["evidence"]:
                if not isinstance(item, dict) or set(item) != {"id", "sha256"} or not re.fullmatch(r"E[1-6]", item["id"]) or not re.fullmatch(r"[a-fA-F0-9]{64}", item["sha256"]) or item["id"] in old_photos:
                    raise Rejected("Invalid previous evidence identity.")
                old_photos[item["id"]] = item["sha256"].lower()
            if set(old_photos) != {i for e in older.values() for i in e["evidenceIds"]}:
                raise Rejected("Previous photo manifest does not match observations.")
            new_photos = {p["id"]: p["sha256"] for p in photos}
            if set(old_photos) - set(new_photos):
                raise Rejected("Supplement must not silently drop previous photo evidence.")
            replacements = set(getattr(args, "replace_evidence_ids", []))
            changed_photos = {i for i in old_photos if old_photos[i] != new_photos[i]}
            if replacements != changed_photos:
                raise Rejected("Photo replacements require the exact explicitly approved evidence IDs.")
            for evidence_id in new_photos:
                old_targets = sorted(k for k, e in older.items() if evidence_id in e["evidenceIds"])
                new_targets = sorted(k for k, e in mapped.items() if evidence_id in e["evidenceIds"])
                if evidence_id not in old_photos:
                    kind = "新增证据"
                elif evidence_id in changed_photos:
                    kind = "明确替换证据（旧报告保留）"
                elif old_targets != new_targets:
                    kind = "证据关联调整"
                else:
                    continue
                evidence_changes.append({"evidenceId": evidence_id, "kind": kind, "targets": new_targets})
        for key in indexed:
            current, old = mapped.get(key), older.get(key)
            if current is None or (old is not None and current["observation"] == old["observation"] and current["reportedResult"] == old["reportedResult"]):
                continue
            if old is None:
                kind = "新增现场描述"
                summary = "原来缺少输入 → " + state_labels[current["reportedResult"]]
            elif old["reportedResult"] != current["reportedResult"]:
                kind = "描述状态变化"
                summary = state_labels[old["reportedResult"]] + " → " + state_labels[current["reportedResult"]]
            else:
                kind = "补充文字"
                summary = "描述已更新，" + state_labels[current["reportedResult"]] + "状态未变"
            changes.append({"requirementId": key, "kind": kind, "summary": summary})
        if not changes and not evidence_changes:
            raise Rejected("Supplement is unchanged; no new report generated.")

    font = Path(args.font)
    pdfmetrics.registerFont(TTFont("FieldCJK", str(font)))
    styles = {
        "title": ParagraphStyle("title", fontName="FieldCJK", fontSize=20, leading=29, spaceAfter=14),
        "head": ParagraphStyle("head", fontName="FieldCJK", fontSize=13, leading=18, spaceBefore=10, spaceAfter=5, keepWithNext=True),
        "body": ParagraphStyle("body", fontName="FieldCJK", fontSize=11, leading=17, spaceAfter=5, wordWrap="CJK"),
        "small": ParagraphStyle("small", fontName="FieldCJK", fontSize=9, leading=14, textColor=colors.HexColor("#5a6573"), wordWrap="CJK"),
    }
    def paragraph(text, style="body"):
        return Paragraph(escape(text).replace("\n", "<br/>"), styles[style])
    counts = {result: sum(e["reportedResult"] == result for e in mapped.values()) for result in ["match", "gap", "unverified"]}
    counts["missing"] = len(indexed) - len(mapped)
    story = [paragraph(title + " · 现场回灌草稿", "title"),
             paragraph("先看结论", "head"),
             paragraph(f"{len(indexed)}项本地要求：用户报告一致{counts['match']}项、差异{counts['gap']}项、未核实{counts['unverified']}项；尚无现场输入{counts['missing']}项。"),
             paragraph("这是一份对照草稿，不是验收通过证明。结论来自用户的现场描述；照片只作为关联证据，不自动证明符合要求。", "small")]
    if changes:
        story.append(paragraph("这次补充改变了什么", "head"))
        story.append(paragraph("\n".join(change["requirementId"] + "：" + change["summary"] for change in changes)))
        story.append(paragraph("以上只比较现场描述与用户报告状态，不是重新测量、照片对比或自动验收。", "small"))
    if evidence_changes:
        story.append(paragraph("这次补充了哪些证据", "head"))
        story.append(paragraph("\n".join(c["evidenceId"] + "：" + c["kind"] + "，关联 " + "、".join(c["targets"]) for c in evidence_changes)))
        story.append(paragraph("仅核对文件字节身份与项目关联，不自动识别图片内容或证明现场已达标。", "small"))
    story.append(paragraph("优先补充", "head"))
    unresolved = [key for key in indexed if key not in mapped or mapped[key]["reportedResult"] != "match"]
    story.append(paragraph("；".join(unresolved) + "：请补充观察、测量或修改意见。" if unresolved else "全部已有一致描述，仍需用户核实并确认最终报告。"))
    story.append(paragraph("本地要求与现场输入逐项对应", "head"))
    labels = {"match": "用户报告：一致", "gap": "用户报告：差异", "unverified": "用户报告：尚未核实"}
    for key, expected in indexed.items():
        entry = mapped.get(key)
        story.append(KeepTogether([paragraph(key + " · " + (labels[entry["reportedResult"]] if entry else "缺少现场输入"), "head"), paragraph("电脑中的要求：" + expected)]))
        story.append(paragraph("手机中的观察：" + entry["observation"] if entry else "手机中的观察：尚未提供，不能推定合格或不合格。"))
        story.append(paragraph("关联证据：" + ("、".join(entry["evidenceIds"]) if entry and entry["evidenceIds"] else "无图片证据，仅文字描述。"), "small"))
    next_id = unresolved[0] if unresolved else next(iter(indexed))
    story += [paragraph("手机怎么继续", "head"), paragraph("可以直接回复：“补充" + next_id + "的现场情况……”或“" + next_id + "这项改成……”。助手先核对你看到的报告和基线，再生成新副本。最终确认前不会对外提交、签字或覆盖电脑原稿。")]
    if photos:
        story.append(paragraph("现场证据索引", "head"))
        for photo in photos:
            story.append(paragraph(photo["id"] + " · 经人工隐私检查的现场图片", "head"))
            picture = Image(str(photo["path"]), width=None, height=None)
            ratio = min(475 / picture.imageWidth, 300 / picture.imageHeight)
            picture.drawWidth, picture.drawHeight = picture.imageWidth * ratio, picture.imageHeight * ratio
            story += [picture, Spacer(1, 8), paragraph("证据 SHA-256（前12位）：" + photo["sha256"][:12], "small")]
    output = Path(args.output)
    manifest_output = output.with_suffix(".json")
    if output.exists() or manifest_output.exists() or not output.parent.is_dir():
        raise Rejected("Output must be a new file in an existing directory.")
    def footer(canvas, doc):
        canvas.setFont("FieldCJK", 8)
        canvas.setFillColor(colors.HexColor("#5a6573"))
        canvas.drawString(42, 26, "现场回灌草稿 · 原件保留 · 未经最终确认")
        canvas.drawRightString(553, 26, str(doc.page))
        canvas.setFont("FieldCJK", 7)
        trace = "版本追溯（SHA-256前12位）：基线 " + args.baseline_sha256[:12] + " / 现场 " + args.observations_sha256[:12]
        if previous_hash:
            trace += " / 前版 " + previous_hash[:12]
        canvas.drawString(42, 14, trace)
    # Render to a uniquely reserved output. No caller-owned file is replaced.
    with output.open("xb") as target:
        SimpleDocTemplate(target, pagesize=(595, 842), leftMargin=42, rightMargin=42,
                          topMargin=42, bottomMargin=48, title="Field review draft", author="Local assistant").build(story, onFirstPage=footer, onLaterPages=footer)
    if output.stat().st_size > 25 * 1024 * 1024:
        raise Rejected("Report exceeds outbound size limit; retained locally only.")
    originals_unchanged = (baseline_path.read_bytes() == baseline_bytes and observation_path.read_bytes() == observation_bytes
                           and (previous_path is None or previous_path.read_bytes() == previous_bytes)
                           and (previous_manifest_path is None or previous_manifest_path.read_bytes() == previous_manifest_bytes)
                           and (previous_report_path is None or digest(previous_report_path.read_bytes()) == previous_report_hash)
                           and all(digest(p["path"].read_bytes()) == p["sha256"] for p in photos))
    if not originals_unchanged:
        raise Rejected("A source changed during rendering; do not deliver this copy.")
    report_hash = digest(output.read_bytes())
    manifest = {"schemaVersion": 1, "baselineSha256": args.baseline_sha256.lower(),
                "observationsSha256": args.observations_sha256.lower(), "reportSha256": report_hash,
                "evidence": [{"id": p["id"], "sha256": p["sha256"]} for p in photos]}
    with manifest_output.open("x", encoding="utf-8") as target:
        json.dump(manifest, target, ensure_ascii=True, indent=2)
    return {"status": "prepared-local-draft", "outputPath": str(output), "sha256": report_hash,
            "requirementCount": len(indexed), "reportedCounts": counts, "evidenceCount": len(photos),
            "originalsUnchanged": True, "acceptance": "requires-human-confirmation", "imageRecognition": "not-performed",
            "textChangeDigest": changes, "evidenceChangeDigest": evidence_changes,
            "evidenceManifestPath": str(manifest_output), "evidenceManifestSha256": digest(manifest_output.read_bytes()),
            "comparisonScope": "reported-text-and-evidence-file-identities" if previous_manifest_path else "observations-and-reported-status-only" if previous_path else "not-compared"}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", required=True)
    parser.add_argument("--observations", required=True)
    parser.add_argument("--baseline-sha256", required=True)
    parser.add_argument("--observations-sha256", required=True)
    parser.add_argument("--previous-observations")
    parser.add_argument("--previous-observations-sha256")
    parser.add_argument("--previous-evidence-manifest")
    parser.add_argument("--previous-evidence-manifest-sha256")
    parser.add_argument("--replace-evidence-ids", nargs="*", default=[])
    parser.add_argument("--evidence", nargs="*", default=[])
    parser.add_argument("--font", required=True)
    parser.add_argument("--output", required=True)
    options = parser.parse_args()
    try:
        print(json.dumps(build(options), ensure_ascii=True))
    except Exception:
        # No raw observations, paths, account information or Python traces.
        print(json.dumps({"status": "rejected", "reason": "Invalid, changed, sensitive or unrenderable input; original files were not edited."}))
        raise SystemExit(2)
