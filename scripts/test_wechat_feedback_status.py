"""Synthetic observer checks; no account data or real message bodies."""
import datetime as dt
import hashlib
import importlib.util
import json
import sqlite3
import subprocess
import tempfile
from pathlib import Path
spec = importlib.util.spec_from_file_location("wechat_feedback_status", Path(__file__).with_name("wechat-feedback-status.py"))
observer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(observer)
status = observer.status

since = dt.datetime.fromisoformat("2026-10-15T04:30:47+08:00")
stamp = int(since.timestamp() * 1000) + 1000
with tempfile.TemporaryDirectory(prefix="wechat-feedback-fixture-") as directory:
    root = Path(directory)
    store = root / "agents" / "demo" / "agent" / "openclaw-agent.sqlite"
    store.parent.mkdir(parents=True)
    with sqlite3.connect(store) as connection:
        connection.executescript("CREATE TABLE session_windows(session_id TEXT,channel TEXT,chat_type TEXT,session_key TEXT); CREATE TABLE transcript_events(session_id TEXT,event_json TEXT,created_at INTEGER,event_zstd BLOB,event_utf8_bytes INTEGER);")
        connection.executemany("INSERT INTO session_windows VALUES(?,?,?,?)", [
            ("direct-fixture", "openclaw-weixin", "direct", "agent:demo:direct:synthetic"),
            ("cron-fixture", "openclaw-weixin", "direct", "agent:demo:cron:synthetic")])
        connection.executemany("INSERT INTO transcript_events(session_id,event_json,created_at) VALUES(?,?,?)", [
            ("direct-fixture", json.dumps({"type": "message", "message": {"role": "user"}}), stamp),
            ("direct-fixture", json.dumps({"type": "message", "message": {"role": "assistant"}}), stamp),
            ("cron-fixture", json.dumps({"type": "message", "message": {"role": "user"}}), stamp)])
    connection.close()
    before = hashlib.sha256(store.read_bytes()).hexdigest()
    result = status(root, since)
    assert result["status"] == "observed" and result["newUserMessages"] == 1
    assert result["messageBodiesPrinted"] is False and result["identifiersPrinted"] is False
    assert hashlib.sha256(store.read_bytes()).hexdigest() == before
    marker = "SYNTHETIC-BODY-MUST-NOT-PRINT"
    payload = json.dumps({"type": "message", "timestamp": (since + dt.timedelta(seconds=1)).isoformat(),
                          "message": {"role": "user", "content": [{"type": "text", "text": marker}]}}).encode()
    compressed = subprocess.run([str(observer.NODE_RUNTIME), "-e", "const f=require('node:fs'),z=require('node:zlib');process.stdout.write(z.zstdCompressSync(f.readFileSync(0)));"],
                                input=payload, capture_output=True, timeout=3, check=True).stdout
    with sqlite3.connect(store) as connection:
        connection.execute("INSERT INTO transcript_events VALUES(?,?,?,?,?)", ("direct-fixture", None, stamp, compressed, len(payload)))
    connection.close()
    before = hashlib.sha256(store.read_bytes()).hexdigest()
    compressed_result = status(root, since)
    assert compressed_result["status"] == "observed" and compressed_result["newUserMessages"] == 2
    assert compressed_result["compressedEventsDecoded"] == 1
    assert marker not in json.dumps(compressed_result)
    assert hashlib.sha256(store.read_bytes()).hexdigest() == before
    decode = subprocess.run([str(observer.NODE_RUNTIME), str(Path(__file__).with_name("wechat-feedback-metadata.mjs")), str(len(payload))],
                            input=compressed, capture_output=True, timeout=3, check=True)
    assert json.loads(decode.stdout)["isUser"] is True
    assert marker.encode() not in decode.stdout + decode.stderr and b"intentHints" not in decode.stdout
    assert observer.compressed_user_metadata(b"invalid-zstd", 20) is None
    assert observer.compressed_user_metadata(compressed, 1024 * 1024 + 1) is None
    with sqlite3.connect(store) as connection:
        connection.execute("INSERT INTO transcript_events(session_id,event_json,created_at) VALUES(?,?,?)", ("direct-fixture", None, stamp))
    connection.close()
    uncertain = status(root, since)
    assert uncertain["status"] == "unverified" and uncertain["newUserMessages"] is None
    assert uncertain["uninspectableRecentEvents"] == 1
print(json.dumps({"status": "passed", "directUserCounted": True, "cronAndAssistantExcluded": True,
                  "databaseUnchangedByObserver": True, "unreadableEventDoesNotMeanZero": True,
                  "compressedUserCountedWithoutBodyOutput": True,
                  "corruptAndOversizedRecordsRemainUnknown": True,
                  "fixtureIsSynthetic": True}))
