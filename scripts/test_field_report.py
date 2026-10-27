"""Local synthetic scene tests; no live WeChat or user project content."""
import argparse
import copy
import hashlib
import json
import tempfile
from pathlib import Path
from types import SimpleNamespace

import field_report
from pypdf import PdfReader


parser = argparse.ArgumentParser()
parser.add_argument("--image", required=True)
parser.add_argument("--second-image")
parser.add_argument("--output-root", required=True)
options = parser.parse_args()
root = Path(options.output_root)
root.mkdir(parents=True, exist_ok=True)
baseline = {"title": "图片证据挂载演练", "requirements": [{"id": "R1", "expected": "关联展示链路示例图片。"}, {"id": "R2", "expected": "待补充下一项现场观察。"}]}
checked = []
with tempfile.TemporaryDirectory(prefix="field-report-test-") as temporary:
    folder = Path(temporary)
    base = folder / "baseline.json"
    base.write_text(json.dumps(baseline, ensure_ascii=False), encoding="utf-8")
    base_hash = hashlib.sha256(base.read_bytes()).hexdigest()
    note = {"baselineSha256": base_hash, "entries": [{"requirementId": "R1", "observation": "模拟输入：关联已检查的链路示例图，不是实际项目现场。", "reportedResult": "unverified", "evidenceIds": ["E1"]}]}
    source = folder / "observations.json"

    def args(value, name, evidence=None):
        source.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")
        return SimpleNamespace(baseline=str(base), observations=str(source), baseline_sha256=base_hash,
                               observations_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
                               evidence=[options.image] if evidence is None else evidence,
                               font=r"C:\Windows\Fonts\simhei.ttf", output=str(root / name))

    result = field_report.build(args(note, "evidence-demo.pdf"))
    pdf = PdfReader(result["outputPath"])
    assert result["evidenceCount"] == 1 and result["originalsUnchanged"]
    assert result["reportedCounts"] == {"match": 0, "gap": 0, "unverified": 1, "missing": 1}
    assert sum(len(page.images) for page in pdf.pages) == 1
    checked.append("mapped-photo-embedded-and-missing-not-approved")

    def rejects(value, name, evidence=None, stale=False):
        request = args(value, name, evidence)
        if stale:
            request.baseline_sha256 = "0" * 64
        try:
            field_report.build(request)
        except field_report.Rejected:
            assert not Path(request.output).exists()
            return
        raise AssertionError("Expected rejection.")

    bad = copy.deepcopy(note)
    bad["entries"][0]["requirementId"] = "R99"
    rejects(bad, "bad-target.pdf")
    checked.append("unknown-project-target-rejected")
    bad = copy.deepcopy(note)
    bad["entries"][0]["evidenceIds"] = ["E2"]
    rejects(bad, "bad-evidence.pdf")
    checked.append("missing-evidence-rejected")
    bad = copy.deepcopy(note)
    bad["entries"].append(copy.deepcopy(bad["entries"][0]))
    rejects(bad, "duplicate-target.pdf")
    checked.append("duplicate-target-rejected")
    bad = copy.deepcopy(note)
    bad["entries"][0]["evidenceIds"] = []
    rejects(bad, "unmapped-photo.pdf")
    checked.append("unmapped-photo-rejected")
    bad = copy.deepcopy(note)
    bad["entries"][0]["observation"] = "context-token: synthetic-redacted-fixture"
    rejects(bad, "sensitive.pdf")
    checked.append("credential-pattern-rejected-without-output")
    rejects(note, "stale.pdf", stale=True)
    checked.append("stale-baseline-rejected")
    duplicate = args(note, "evidence-demo.pdf")
    original = Path(duplicate.output).read_bytes()
    try:
        field_report.build(duplicate)
    except field_report.Rejected:
        assert Path(duplicate.output).read_bytes() == original
    else:
        raise AssertionError("Existing output must not be replaced.")
    checked.append("existing-report-preserved")

    old_text = {"baselineSha256": base_hash, "entries": [{"requirementId": "R1", "observation": "模拟旧描述：尚有差异。", "reportedResult": "gap", "evidenceIds": []}]}
    previous = folder / "previous.json"
    previous.write_text(json.dumps(old_text, ensure_ascii=False), encoding="utf-8")
    previous_hash = hashlib.sha256(previous.read_bytes()).hexdigest()
    new_text = copy.deepcopy(old_text)
    new_text["entries"][0].update(observation="模拟补充：已调整，但尚未核实。", reportedResult="unverified")
    new_text["entries"].append({"requirementId": "R2", "observation": "模拟补充：已取得现场描述。", "reportedResult": "match", "evidenceIds": []})

    def supplementary(value, name):
        request = args(value, name, evidence=[])
        request.previous_observations = str(previous)
        request.previous_observations_sha256 = previous_hash
        return request

    updated = field_report.build(supplementary(new_text, "text-supplement-demo.pdf"))
    assert [c["requirementId"] for c in updated["textChangeDigest"]] == ["R1", "R2"]
    assert updated["reportedCounts"]["unverified"] == 1
    assert "这次补充改变了什么" in "".join(p.extract_text() for p in PdfReader(updated["outputPath"]).pages)
    assert hashlib.sha256(previous.read_bytes()).hexdigest() == previous_hash
    checked.append("supplement-digest-and-previous-copy-preserved")
    for value, name, stale in [(old_text, "same-supplement.pdf", False),
                               ({"baselineSha256": base_hash, "entries": []}, "dropped-observation.pdf", False),
                               (new_text, "old-revision-mismatch.pdf", True)]:
        request = supplementary(value, name)
        if stale:
            request.previous_observations_sha256 = "0" * 64
        try:
            field_report.build(request)
        except field_report.Rejected:
            assert not Path(request.output).exists()
        else:
            raise AssertionError("Invalid supplement should be rejected.")
    checked.append("unchanged-dropped-and-stale-supplements-rejected")

    if options.second_image:
        photo_original = field_report.build(args(note, "photo-original.pdf"))
        photo_previous = folder / "previous-photo-observations.json"
        photo_previous.write_bytes(source.read_bytes())
        photo_previous_hash = hashlib.sha256(photo_previous.read_bytes()).hexdigest()
        old_report_hash = hashlib.sha256(Path(photo_original["outputPath"]).read_bytes()).hexdigest()

        def photo_revision(value, name, images, replacements=None):
            request = args(value, name, evidence=images)
            request.previous_observations = str(photo_previous)
            request.previous_observations_sha256 = photo_previous_hash
            request.previous_evidence_manifest = photo_original["evidenceManifestPath"]
            request.previous_evidence_manifest_sha256 = photo_original["evidenceManifestSha256"]
            request.replace_evidence_ids = replacements or []
            return request

        added = copy.deepcopy(note)
        added["entries"].append({"requirementId": "R2", "observation": "追加匿名报告截图作为第二个测试证据，不是实际现场。", "reportedResult": "unverified", "evidenceIds": ["E2"]})
        addition = field_report.build(photo_revision(added, "photo-addition.pdf", [options.image, options.second_image]))
        assert addition["evidenceChangeDigest"] == [{"evidenceId": "E2", "kind": "新增证据", "targets": ["R2"]}]
        assert addition["evidenceCount"] == 2 and addition["originalsUnchanged"]
        checked.append("new-photo-linked-with-previous-evidence-preserved")
        replacement = field_report.build(photo_revision(note, "photo-approved-replacement.pdf", [options.second_image], ["E1"]))
        assert replacement["textChangeDigest"] == []
        assert replacement["evidenceChangeDigest"][0]["kind"] == "明确替换证据（旧报告保留）"
        assert hashlib.sha256(Path(photo_original["outputPath"]).read_bytes()).hexdigest() == old_report_hash
        checked.append("explicit-replacement-keeps-old-report-and-does-not-claim-text-changed")
        dropped = copy.deepcopy(note)
        dropped["entries"][0]["evidenceIds"] = []
        bad_requests = [photo_revision(note, "photo-silent-replacement.pdf", [options.second_image]),
                        photo_revision(dropped, "photo-dropped.pdf", []),
                        photo_revision(added, "photo-wrong-manifest.pdf", [options.image, options.second_image])]
        bad_requests[-1].previous_evidence_manifest_sha256 = "0" * 64
        for request in bad_requests:
            try:
                field_report.build(request)
            except field_report.Rejected:
                assert not Path(request.output).exists()
            else:
                raise AssertionError("Invalid photo revision should be rejected.")
        checked.append("silent-replacement-dropped-photo-and-wrong-manifest-rejected")
print(json.dumps({"status": "passed", "checks": checked, "pageCount": len(pdf.pages), "livePhoneTest": False}, ensure_ascii=True))
