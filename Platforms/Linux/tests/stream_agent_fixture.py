"""A deterministic stream-json agent for the native stream-conversation diagnostic.

It speaks the subset of Claude Code's headless wire that `StreamEvent.parse` reads: one
`system/init`, partial `text_delta` stream events, complete assistant messages with text and an
Edit `tool_use`, the matching `tool_result`, and a `result` per turn. The process stays alive
across turns, as the real CLI does, and exits 0 when stdin closes. Nothing here reaches a network
or a provider; every line is fixed by the prompt it answers.
"""
import json
import os
import sys
import time

DELTA_PAUSE = float(os.environ.get("STREAM_FIXTURE_DELTA_PAUSE", "0.25"))
OLD = 'func greeting() -> String {\n    return "Hello"\n}\n'
NEW = 'func greeting() -> String {\n    // Unicode é, räksmörgås, 中文 and 👩🏽‍🚀\n    return "Hello, Linux"\n}\n'
REPLY = (
    "## Streaming through the shared transport\n\n"
    "This reply arrived **a line at a time** from a child process. Unicode stays whole: "
    "é, räksmörgås, 中文 and 👩🏽‍🚀.\n\n"
    "- The production transport framed it.\n"
    "- The production parser and timeline reduced it.\n\n"
    "```swift\nprint(\"Hello, Linux\")\n```"
)


def emit(value):
    sys.stdout.write(json.dumps(value, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def delta(text):
    emit({"type": "stream_event",
          "event": {"type": "content_block_delta", "delta": {"type": "text_delta", "text": text}}})


def first_turn():
    emit({"type": "system", "subtype": "init", "session_id": "fixture-stream-session",
          "model": "fixture-model"})
    for part in ["## Streaming through ", "the shared transport\n\nThis reply arrived ",
                 "**a line at a time**"]:
        delta(part)
        time.sleep(DELTA_PAUSE)
    emit({"type": "assistant", "message": {"content": [
        {"type": "text", "text": REPLY},
        {"type": "tool_use", "id": "stream-edit", "name": "Edit",
         "input": {"file_path": "/tmp/greeting.swift", "old_string": OLD, "new_string": NEW}},
    ]}})
    time.sleep(DELTA_PAUSE)
    emit({"type": "user", "message": {"content": [
        {"type": "tool_result", "tool_use_id": "stream-edit", "content": "Applied edit",
         "is_error": False},
    ]}})
    emit({"type": "result", "subtype": "success", "result": REPLY, "is_error": False,
          "duration_ms": 1250, "usage": {"output_tokens": 42}})


def later_turn(prompt):
    reply = f"Second turn, same process. You wrote: {prompt}"
    delta("Second turn, ")
    time.sleep(DELTA_PAUSE)
    emit({"type": "assistant", "message": {"content": [{"type": "text", "text": reply}]}})
    emit({"type": "result", "subtype": "success", "result": reply, "is_error": False,
          "duration_ms": 300})


def prompt_text(line):
    message = json.loads(line).get("message", {})
    return "".join(block.get("text", "") for block in message.get("content", [])
                   if isinstance(block, dict) and block.get("type") == "text")


def main():
    sys.stderr.write("stream fixture agent ready\n")
    sys.stderr.flush()
    turns = 0
    for line in sys.stdin:
        if not line.strip():
            continue
        prompt = prompt_text(line)
        turns += 1
        if turns == 1:
            first_turn()
        else:
            later_turn(prompt)
    sys.stderr.write(f"stream fixture agent answered {turns} turns\n")


if __name__ == "__main__":
    main()
