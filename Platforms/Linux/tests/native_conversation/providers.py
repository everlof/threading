"""Deterministic protocol peers for the unmodified production session classes."""
import json
import sys

mode = sys.argv[1]
turn = 0
text = "日本語 🧵 café"


def emit(value):
    print(json.dumps(value, ensure_ascii=False), flush=True)


def response(request, result):
    emit({"jsonrpc": "2.0", "id": request["id"], "result": result})


def notification(method, params):
    emit({"jsonrpc": "2.0", "method": method, "params": params})


for line in sys.stdin:
    request = json.loads(line)
    if mode == "claude":
        if request["type"] == "control_request":
            emit({"type": "control_response", "response": {
                "subtype": "success", "request_id": request["request_id"],
                "response": {"commands": [{"name": "compact", "description": "Compact"}]}}})
        elif request["type"] == "user":
            turn += 1
            assert request["message"]["content"][0]["text"] == f"prompt {turn} {text}"
            if turn == 1:
                emit({"type": "system", "subtype": "init", "session_id": "claude-contract",
                      "model": "fixture", "slash_commands": ["compact"]})
            emit({"type": "stream_event", "event": {"type": "content_block_delta",
                  "delta": {"type": "text_delta", "text": text}}})
            emit({"type": "assistant", "message": {"content": [{"type": "text", "text": text}]}})
            emit({"type": "result", "subtype": "success", "result": text,
                  "is_error": False, "duration_ms": 5, "num_turns": 1})
    elif mode == "codex":
        method = request.get("method")
        if method == "initialize":
            response(request, {})
        elif method == "initialized":
            pass
        elif method == "thread/start":
            response(request, {"thread": {"id": "thread-contract", "model": "fixture"}})
        elif method == "skills/list":
            response(request, {"data": [{"cwd": "/tmp", "skills": [], "errors": []}]})
        elif method == "turn/start":
            turn += 1
            assert request["params"]["input"][0]["text"] == f"prompt {turn} {text}"
            tid = f"turn-{turn}"
            response(request, {"turn": {"id": tid}})
            notification("turn/started", {"threadId": "thread-contract", "turn": {"id": tid}})
            notification("item/agentMessage/delta", {"threadId": "thread-contract", "turnId": tid, "delta": text})
            emit({"id": f"approval-{turn}", "method": "item/commandExecution/requestApproval",
                  "params": {"threadId": "thread-contract", "turnId": tid,
                             "command": "printf inspected", "cwd": "/tmp"}})
        elif request.get("id", "").startswith("approval-"):
            assert request["result"]["decision"] == ("decline" if turn == 1 else "accept")
            tid = f"turn-{turn}"
            notification("item/completed", {"threadId": "thread-contract", "turnId": tid,
                         "item": {"type": "agentMessage", "id": f"answer-{turn}", "text": text}})
            notification("turn/completed", {"threadId": "thread-contract",
                         "turn": {"id": tid, "status": "completed", "items": []}})
        else:
            raise AssertionError(request)
    else:
        method = request.get("method")
        if method == "initialize":
            response(request, {"protocolVersion": 1})
        elif method == "session/new":
            response(request, {"sessionId": "acp-contract", "models": {"currentModelId": "fixture"}})
        elif method == "session/prompt":
            turn += 1
            assert request["params"]["prompt"][0]["text"] == f"prompt {turn} {text}"
            notification("session/update", {"sessionId": "acp-contract", "update": {
                "sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}}})
            response(request, {"stopReason": "end_turn"})
        elif method == "session/cancel":
            pass
        else:
            raise AssertionError(request)
