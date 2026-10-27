"""Read aggregate WeChat feedback metadata, never export message bodies or IDs.

OpenClaw 2026.10.2 uses the agent SQLite store. Do not assume sessions.json
absence means no feedback. This observer is not a message executor or grantor.
"""
import argparse
import os
import shutil
import datetime as dt
import json
import sqlite3
import subprocess
from pathlib import Path

def resolve_node_runtime() -> Path:
    override = os.environ.get("WECHAT_AGENT_NODE")
    if override:
        candidate = Path(override).expanduser().resolve()
        if candidate.is_file():
            return candidate
        raise RuntimeError("WECHAT_AGENT_NODE does not point to a file")
    runtime_root = Path(os.environ.get("CODEX_RUNTIME_ROOT", Path.home() / ".cache" / "codex-runtimes"))
    if runtime_root.is_dir():
        directories = sorted(
            (entry for entry in runtime_root.iterdir() if entry.is_dir()),
            key=lambda entry: (entry.name != "codex-primary-runtime", -entry.stat().st_mtime),
        )[:20]
        for directory in directories:
            candidate = directory / "dependencies" / "node" / "bin" / "node.exe"
            if candidate.is_file():
                return candidate.resolve()
    command = shutil.which("node")
    if command:
        return Path(command).resolve()
    raise RuntimeError("Unable to resolve node runtime; set WECHAT_AGENT_NODE")

NODE_RUNTIME = resolve_node_runtime()


def compressed_user_metadata(blob, expected_bytes):
    limit = 1024 * 1024
    if not isinstance(blob, bytes) or not blob or len(blob) > limit or not isinstance(expected_bytes, int) or not 0 < expected_bytes <= limit:
        return None
    try:
        result = subprocess.run([str(NODE_RUNTIME), str(Path(__file__).with_name("wechat-feedback-metadata.mjs")), str(expected_bytes)],
                                input=blob, capture_output=True, timeout=3, check=False)
        if result.returncode != 0:
            return None
        value = json.loads(result.stdout)
        if value.get("decoded") is not True or not isinstance(value.get("isUser"), bool):
            return None
        return value["isUser"]
    except Exception:
        return None


def status(state_root, since):
    if since.tzinfo is None:
        raise ValueError("Timezone required.")
    root = Path(state_root).resolve(strict=True)
    stores = list((root / "agents").glob("*/agent/openclaw-agent.sqlite"))
    counts = {"readableStores": 0, "directWechatWindows": 0, "newUserMessages": 0,
              "uninspectableRecentEvents": 0, "compressedEventsDecoded": 0}
    decode_attempts = 0
    cutoff = int(since.timestamp() * 1000)
    for store in stores:
        if store.resolve(strict=True) != store.absolute():
            raise ValueError("Linked store unsupported.")
        # mode=ro fails rather than creating a new DB; no immutable=1 because
        # that would ignore the live WAL and can silently miss recent messages.
        connection = sqlite3.connect(store.as_uri() + "?mode=ro", uri=True, timeout=2)
        try:
            connection.execute("PRAGMA query_only=ON")
            connection.execute("BEGIN")
            parameters = ("openclaw-weixin", "direct", "%:cron:%")
            windows = connection.execute(
                "SELECT count(*) FROM session_windows WHERE channel=? AND chat_type=? "
                "AND session_key NOT LIKE ?", parameters).fetchone()[0]
            counts["directWechatWindows"] += windows
            columns = {row[1] for row in connection.execute("PRAGMA table_info(transcript_events)")}
            compressed_columns = "e.event_zstd, e.event_utf8_bytes" if {"event_zstd", "event_utf8_bytes"} <= columns else "NULL, NULL"
            # Read only scalar metadata through JSON extraction. No text,
            # session IDs, peer IDs, context tokens or route contexts returned.
            rows = connection.execute(
                "SELECT json_extract(e.event_json,'$.type'), "
                "json_extract(e.event_json,'$.message.role'), e.event_json IS NULL, " + compressed_columns + " "
                "FROM transcript_events e JOIN session_windows w ON e.session_id=w.session_id "
                "WHERE w.channel=? AND w.chat_type=? AND w.session_key NOT LIKE ? "
                "AND e.created_at>?", (*parameters, cutoff))
            for event_type, role, missing, blob, expected_bytes in rows:
                if missing:
                    is_user = None
                    if decode_attempts < 32 and blob is not None:
                        decode_attempts += 1
                        is_user = compressed_user_metadata(blob, expected_bytes)
                    if is_user is None:
                        counts["uninspectableRecentEvents"] += 1
                    else:
                        counts["compressedEventsDecoded"] += 1
                        counts["newUserMessages"] += int(is_user)
                elif event_type == "message" and role == "user":
                    counts["newUserMessages"] += 1
            counts["readableStores"] += 1
        finally:
            connection.close()
    complete = (bool(stores) and counts["directWechatWindows"] > 0
                and counts["uninspectableRecentEvents"] == 0)
    return {"status": "observed" if complete else "unverified", "backend": "agent-sqlite-read-only",
            "since": since.isoformat(), **counts,
            "newUserMessages": counts["newUserMessages"] if complete else None,
            "coverage": "currently-present-direct-wechat-windows-not-cron",
            "timestampMeaning": "store-event-created-at", "messageBodiesPrinted": False,
            "identifiersPrinted": False, "completeForVisibleStores": complete}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--state-root", required=True)
    parser.add_argument("--since", required=True)
    args = parser.parse_args()
    try:
        result = status(args.state_root, dt.datetime.fromisoformat(args.since))
        print(json.dumps(result, ensure_ascii=True))
    except Exception:
        print(json.dumps({"status": "unverified", "newUserMessages": None,
                          "reason": "Store unavailable or schema unsupported; absence is not confirmed.",
                          "messageBodiesPrinted": False, "identifiersPrinted": False}))
        raise SystemExit(2)
