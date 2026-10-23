"""Capture stock Dashboard contracts in an isolated disposable SessionDB.

Run with the backend's Python: python tools/capture_task_history_fixture.py BACKEND_ROOT.
No server is contacted and no existing profile or conversation is modified.
"""
import asyncio
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from unittest.mock import patch

backend = Path(sys.argv[1]).resolve()
sys.path.insert(0, str(backend))
from hermes_state import SessionDB  # noqa: E402
from hermes_cli.web_routers import sessions  # noqa: E402
from tools import delegate_tool_registry as registry  # noqa: E402


async def capture(home):
    db = SessionDB(db_path=home / "fixture.db")
    db.create_session("parent-chat", source="cli", profile_name="fixture")
    db.append_message("parent-chat", "assistant", "PARENT transcript must not leak")
    db.create_session("stored-child", source="subagent", profile_name="fixture",
                      parent_session_id="parent-chat", model_config={"_delegate_from": "parent-chat"})
    db.append_message("stored-child", "user", "Inspect the fixture")
    db.append_message("stored-child", "assistant", "", reasoning="Archived exposed reasoning",
                      tool_calls=[{"id": "archived-call", "type": "function", "function": {
                          "name": "terminal", "arguments": '{"command":"pwd"}'}}])
    db.append_message("stored-child", "tool", "Archived tool result", tool_call_id="archived-call")
    db.append_message("stored-child", "assistant", "Before compaction")
    db.append_message("stored-child", "user", "Continue")
    db.append_message("stored-child", "assistant", "Tail answer")
    tail = db.get_messages("stored-child")[-2:]
    db.archive_and_compact("stored-child", [{"role": "user", "content": "[summary]"}, *tail], tail_count=2)
    commentary = {"type": "message", "role": "assistant", "phase": "commentary",
                  "content": [{"type": "output_text", "text": "Public progress"}]}
    db.append_message("stored-child", "assistant", "", reasoning="Public progress\n\nExposed reasoning",
                      codex_message_items=[commentary],
                      codex_reasoning_items=[{"summary": [{"type": "summary_text", "text": "Exposed reasoning"}]}])
    db.end_session("stored-child", "compression")
    db.create_session("compression-tip", source="subagent", profile_name="fixture", parent_session_id="stored-child")
    db.append_message("compression-tip", "assistant", "After rotation")
    db.create_session("missing-child-longer", source="cli", profile_name="fixture")
    db.append_message("missing-child-longer", "assistant", "FOREIGN transcript")

    async def messages(sid, compacted):
        return await sessions.get_session_messages(sid, profile="fixture", limit=50, offset=0,
                                                  order="latest", include_compacted=compacted, inline_images=False)

    try:
        with patch.object(sessions, "_with_db", lambda profile, fn, **kwargs: fn(db)), \
             patch.object(sessions, "_serving_profile", lambda profile: profile), \
             patch.object(sessions, "_history_profile_home", lambda profile: home), \
             patch("hermes_cli.config.load_config", return_value={"display": {"show_commentary": True}}):
            result = {"backend_commit": subprocess.check_output(["git", "-C", str(backend), "rev-parse", "HEAD"], text=True).strip(),
                      "detail": await sessions.get_session_detail("stored-child", profile="fixture"),
                      "tip_detail": await sessions.get_session_detail("compression-tip", profile="fixture"),
                      "prefix_detail": await sessions.get_session_detail("missing-child", profile="fixture"),
                      "without_compacted": await messages("stored-child", False),
                      "with_compacted": await messages("stored-child", True),
                      "prefix_messages": await messages("missing-child", True)}
            with patch("hermes_cli.config.load_config", return_value={"display": {"show_commentary": False}}):
                result["commentary_disabled"] = await messages("stored-child", True)
        with patch.dict(registry._active_subagents, {"runtime": {"subagent_id": "runtime"}}, clear=True), \
             patch.object(registry, "_owns_subagent_record", return_value=True), \
             patch.object(registry, "steer_subagent", return_value=True), \
             patch.object(registry, "interrupt_subagent", return_value=True):
            result["steer_ack"] = json.loads(registry._handle_control_action("steer", "runtime", "Keep going", None))
            result["stop_ack"] = json.loads(registry._handle_control_action("stop", "runtime", None, None))
        archived = result["with_compacted"]["messages"]
        assert any(m.get("content") == "Archived tool result" for m in archived)
        assert not any("PARENT transcript" in (m.get("content") or "") for m in archived)
        assert not any(m.get("content") == "Archived tool result" for m in result["without_compacted"]["messages"])
        assert result["prefix_detail"]["id"] == "missing-child-longer"
        assert result["with_compacted"]["session_id"] == "compression-tip"
        return result
    finally:
        db.close()


with tempfile.TemporaryDirectory(prefix="task-history-contract-", dir=os.environ["TMPDIR"]) as directory:
    captured = asyncio.run(capture(Path(directory)))
output = Path(__file__).resolve().parents[1] / "test/fixtures/delegated_task_dashboard.json"
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(json.dumps(captured, ensure_ascii=False, indent=2) + "\n")
print(f"Captured actual Dashboard detail/messages, compacted history, prefix resolution and control ACKs: {output}")
