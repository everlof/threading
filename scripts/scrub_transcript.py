#!/usr/bin/env python3
"""Turn a real agent transcript into a committable test fixture.

The fixtures under `Tests/Fixtures/Transcripts` are real conversations with their
content replaced. Content is what the parsers and the renderer must not depend on;
*shape* is what they are tested against, so shape is preserved exactly:

- every JSON key, type tag, role, status and standard tool name is kept verbatim
- markdown syntax survives — headings stay headings, fences stay fences, list
  markers, emphasis and inline code all keep their delimiters, so `MarkdownView`
  is exercised on the same block structure the real conversation had
- code keeps its indentation and line count; only identifiers and literals move
- substitution is a deterministic per-token map, so an `Edit`'s `old_string` and
  `new_string` still differ in exactly the lines they differed in before, and
  `EditDiff`'s alignment walk sees a real diff rather than two unrelated blobs
- identifiers (tool-use ids, session uuids) are remapped consistently, so
  tool results still attach to their calls

Usage:
    scrub_transcript.py --kind claude --in <path.jsonl> --out <fixture.jsonl> [--max-records N]
"""

import argparse
import hashlib
import json
import re
import sys

# MARK: - Vocabulary

# A fixed word list, indexed by hash. Deterministic, so the same input token maps to
# the same output token in every file and across runs — which is what keeps diffs
# diff-shaped and tool results attached to their calls.
WORDS = """alder amber anchor arbor aspen basin beacon birch bramble briar brook cedar
cinder clover cobble copse coral cove crest dale delta dune ember fallow fen fjord flint
forge frost gable glade gorse grove harbor hazel heath hollow juniper kelp larch ledge
linden loam maple marsh meadow mesa moor moss myrtle notch oak orchard pebble pike pine
quarry reed ridge rill rowan sable sedge shale shoal slate sorrel spruce stack stone
tarn thicket thistle tide timber vale verge willow"""
WORDS = WORDS.split()

# Kept verbatim: the renderer branches on these, so changing them changes the test.
KEEP_KEYS = {
    "type", "role", "status", "subtype", "hook_event_name", "stop_reason",
    "is_error", "isMeta", "isSidechain", "isCompactSummary", "leafUuid",
}

# Tool names the app has rendering rules for (`ToolCallView`, `EditDiff`).
KEEP_TOOL_NAMES = {
    "Bash", "Read", "Write", "Edit", "MultiEdit", "Glob", "Grep", "NotebookRead",
    "NotebookEdit", "Task", "Agent", "WebFetch", "WebSearch", "TodoWrite", "TodoRead",
    "ToolSearch", "Skill", "TaskCreate", "TaskUpdate", "TaskList", "AskUserQuestion",
    "Artifact", "Workflow", "SendMessage", "ScheduleWakeup",
    # Codex item names, mapped by `TranscriptReplay.codexToolName`.
    "exec", "exec_command", "apply_patch", "file_change", "web_search", "view_image",
    "update_plan", "write_stdin", "shell",
    "spawn_agent", "wait_agent", "close_agent", "list_agents", "send_message", "wait",
}

# Structural keys whose *values* carry no content but must stay internally consistent.
ID_KEYS = {"id", "uuid", "parentUuid", "call_id", "tool_use_id", "session_id", "sessionId"}

# Free-text keys that should keep their markdown/code structure.
CODE_KEYS = {"old_string", "new_string", "content", "command", "input", "output", "text"}

KEYWORDS = set("""
func let var if else guard return class struct enum extension protocol import
private public internal static override init self nil true false for in while switch
case default throw throws try catch async await weak lazy final where as is do
def return import from class self None True False elif print raise with lambda
function const export interface type extends implements new this null undefined
echo cd ls cat grep find rm mv cp mkdir git npm swift xcodebuild python3 sudo
Begin End Patch Add Update Delete File Move
""".lower().split())
# Lowercased at construction because the lookup is `token.lower()`: `None`, `True` and `False`
# were listed capitalized and so had never matched anything.
# The last line is Codex's `apply_patch` envelope (`*** Begin Patch`, `*** Add File: …`).
# Scrubbed as prose it became `*** Fallo Ancho`, and the fixture then exercised a patch format
# no CLI emits — which is exactly the class of bug these fixtures exist to find.


# Argument names. Values are content and must move; *names* are schema and must not — the
# renderer looks them up by name, so renaming them produces a fixture that exercises a schema
# no CLI emits. This bit twice: once for arguments persisted as a string of JSON, and again for
# Codex's `exec` wrapper, whose argument is a line of JavaScript
# (`await tools.exec_command({cmd: "…"})`) where the same names appear as identifiers.
KEEP_ARGUMENT_NAMES = {
    "tools", "cmd", "command", "workdir", "yield_time_ms", "max_output_tokens", "session_id",
    "chars", "plan", "step", "status", "patch", "path", "file_path", "old_string", "new_string",
    "content", "edits", "query", "pattern", "url", "description", "message", "prompt",
    "agent_type", "fork_context", "targets", "timeout_ms", "offset", "limit", "notebook_path",
    "replace_all", "timeout", "subagent_type", "todos", "activeForm",
}


def stable_index(token, modulus):
    digest = hashlib.sha256(token.encode("utf-8")).digest()
    return int.from_bytes(digest[:4], "big") % modulus


def map_word(token):
    """Replace one word, preserving case shape and rough length."""
    if token.lower() in KEYWORDS:
        return token
    if token in KEEP_ARGUMENT_NAMES or token in KEEP_TOOL_NAMES:
        return token

    replacement = WORDS[stable_index(token.lower(), len(WORDS))]

    # Keep long tokens long, so wrapping and truncation behave as they did.
    while len(replacement) < len(token) - 2:
        replacement += "_" + WORDS[stable_index(replacement, len(WORDS))]
    replacement = replacement[: max(len(token), 3)]

    if token.isupper() and len(token) > 1:
        return replacement.upper()
    if token[:1].isupper():
        return replacement.capitalize()
    return replacement


# Everything that must survive a substitution untouched, in one pass.
TOKEN = re.compile(
    r"""(?P<escape>\\.)
      | (?P<url>https?://\S+)
      | (?P<email>[\w.+-]+@[\w-]+\.[\w.]+)
      | (?P<path>(?:/|~/|\./)[\w./~-]{2,})
      | (?P<word>[A-Za-z_][A-Za-z0-9_]*)
    """,
    re.VERBOSE,
)
# `escape` comes first and is passed through untouched. Without it the `n` of a `\n` inside an
# embedded string literal was scrubbed like any other word, turning every newline in Codex's
# JavaScript wrapper into `\ced` — the fixture then held a patch that no parser could split
# into lines, and the bug looked like ours.


def scrub_path(path):
    parts = [p for p in path.replace("~", "").split("/") if p]
    mapped = []
    for part in parts:
        stem, dot, ext = part.rpartition(".")
        if dot and len(ext) <= 5 and ext.isalpha():
            mapped.append(map_word(stem or part) + "." + ext)
        else:
            mapped.append(map_word(part))
    prefix = "/" if path.startswith("/") else ("~/" if path.startswith("~") else "./")
    return prefix + "/".join(mapped)


def scrub_text(text):
    """Replace content, keep every non-word character — so markdown and code survive."""
    def replace(match):
        if match.group("escape"):
            return match.group("escape")
        if match.group("url"):
            return "https://" + map_word(match.group("url")) + ".example.com"
        if match.group("email"):
            return map_word(match.group("email")) + "@example.com"
        if match.group("path"):
            return scrub_path(match.group("path"))
        return map_word(match.group("word"))

    return TOKEN.sub(replace, text)


def scrub_id(value):
    """Remap an identifier consistently, keeping its shape so parsers still match it."""
    digest = hashlib.sha256(value.encode("utf-8")).hexdigest()
    out = []
    index = 0
    for character in value:
        if character.isalnum():
            out.append(digest[index % len(digest)])
            index += 1
        else:
            out.append(character)
    return "".join(out)


# A key that is data rather than schema. Claude's `toolUseResult` keys some objects by
# file path (`trackedFileBackups`, `changes`), so a scrubber that only walked values left
# every edited path in the fixture verbatim — found by auditing the output, not by reading
# the writer. Keys shaped like identifiers are schema and must survive untouched.
SCHEMA_KEY = re.compile(r"^[A-Za-z_][A-Za-z0-9_.-]*$")


def scrub_key(key):
    return key if SCHEMA_KEY.match(key) else scrub_text(key)


def scrub(node, key=None):
    if isinstance(node, dict):
        return {scrub_key(k): scrub(v, key=k) for k, v in node.items()}
    if isinstance(node, list):
        return [scrub(v, key=key) for v in node]
    if not isinstance(node, str):
        return node

    if key in KEEP_KEYS:
        return node
    if key == "name" and node in KEEP_TOOL_NAMES:
        return node
    if key == "name" and node.startswith("mcp__"):
        # Keep the `mcp__server__tool` shape — the renderer splits on it — but not the
        # server's real name, which says which services the user has connected.
        parts = node.split("__")
        return "mcp__" + map_word(parts[1] if len(parts) > 1 else "server") + "__" + (
            map_word(parts[2]) if len(parts) > 2 else "tool"
        )
    if key in ID_KEYS:
        return scrub_id(node)
    if key in ("model", "version", "cli_version", "cwd", "gitBranch", "timestamp"):
        # `cli_version` stays: `CodexRolloutFormat` documents which releases wrote which
        # record shapes, and a fixture is evidence of that only while it says who wrote it.
        return node if key in ("model", "version", "cli_version", "timestamp") else scrub_text(node)

    # Codex persists a tool call's arguments as a *string of JSON*, so scrubbing it as prose
    # renamed the keys inside it — `cmd` became `dun` — and the fixture then exercised a
    # schema the real files never have. Re-scrub it as JSON and re-serialize, so argument
    # names survive and only their values move.
    if node.startswith(("{", "[")):
        try:
            return json.dumps(scrub(json.loads(node)), separators=(",", ":"))
        except (json.JSONDecodeError, ValueError):
            pass

    return scrub_text(node)


# MARK: - Windowing

def claude_records(lines):
    for line in lines:
        try:
            yield json.loads(line)
        except json.JSONDecodeError:
            continue


def codex_user_turn(payload):
    """A typed user turn in either Codex shape.

    Up to 0.146 it is a `user_message` event; from 0.147 it is an `item_completed` event whose
    item is a `UserMessage`. `CodexRolloutFormat` in the app holds the same two names.
    """
    if payload.get("type") == "user_message":
        return True
    return payload.get("type") == "item_completed" and (
        (payload.get("item") or {}).get("type") == "UserMessage"
    )


def coverage(window, kind):
    """Score a candidate window by how much of the renderer it exercises.

    A fixture is only worth committing for what it covers, and coverage is not evenly
    spread through a conversation — a real session has long stretches of nothing but
    `exec_command`. Taking the first window that starts on a user turn produced fixtures
    with no `Edit` at all, so `EditDiff` went untested by the very files meant to test it.
    Every window is scored instead, and the best one wins.
    """
    tools, edits, thinking, markdown, users = set(), 0, 0, set(), 0

    for record in window:
        payload = record.get("payload") or {}
        kind_tag = record.get("type")

        if kind_tag == "event_msg":
            if codex_user_turn(payload):
                users += 1
            elif payload.get("type") == "agent_reasoning":
                thinking += 1
            elif payload.get("type") == "item_completed" and (
                (payload.get("item") or {}).get("type") == "Reasoning"
            ):
                thinking += 1
        elif kind_tag == "response_item" and payload.get("type") in (
            "custom_tool_call", "function_call"
        ):
            tools.add(payload.get("name"))
            if payload.get("name") in ("apply_patch", "file_change"):
                edits += 1
        elif kind_tag == "user" and not record.get("isMeta"):
            users += 1
        elif kind_tag == "assistant":
            for block in (record.get("message") or {}).get("content") or []:
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "tool_use":
                    tools.add(block.get("name"))
                    if block.get("name") in ("Edit", "MultiEdit"):
                        edits += 1
                elif block.get("type") == "thinking":
                    thinking += 1
                elif block.get("type") == "text":
                    text = block.get("text") or ""
                    for name, pattern in (
                        ("heading", r"^#{1,3} "), ("fence", r"```"),
                        ("list", r"^\s*[-*\d.]+ "), ("code", r"`[^`\n]+`"),
                        ("bold", r"\*\*[^*\n]+\*\*"), ("table", r"^\|"),
                    ):
                        if re.search(pattern, text, re.M):
                            markdown.add(name)

    # Edits and markdown variety are weighted hardest: they are the parts with real
    # rendering logic behind them, where a tenth `exec_command` adds nothing.
    return (len(tools) * 8 + min(edits, 6) * 14 + len(markdown) * 10
            + min(thinking, 8) * 4 + min(users, 8) * 3)


def pick_window(records, kind, limit):
    """Take the best-covering contiguous slice that starts on a user turn.

    Contiguous because tool calls and their results are separate records: a filtered
    selection would strand results whose call is no longer present, which is a state
    the real files never produce and the renderer is not written for.
    """
    def is_user(record):
        if kind == "claude":
            return record.get("type") == "user" and not record.get("isMeta")
        payload = record.get("payload") or {}
        return record.get("type") == "event_msg" and codex_user_turn(payload)

    # Skip the opening turn: for Codex it carries the project's whole instruction block,
    # and for Claude the CLI's own preamble — neither is conversation.
    starts = [i for i, r in enumerate(records) if is_user(r)][1:]
    if not starts:
        return records[:limit]

    start = max(starts, key=lambda i: coverage(records[i:i + limit], kind))
    window = records[start:start + limit]

    seen = set()
    for record in window:
        message = record.get("message") or {}
        for block in message.get("content") or []:
            if isinstance(block, dict) and block.get("type") == "tool_use":
                seen.add(block.get("id"))
        payload = record.get("payload") or {}
        if payload.get("type") in ("custom_tool_call", "function_call"):
            seen.add(payload.get("call_id"))

    def keep(record):
        message = record.get("message") or {}
        content = message.get("content")
        if isinstance(content, list):
            kept = [
                b for b in content
                if not (isinstance(b, dict) and b.get("type") == "tool_result"
                        and b.get("tool_use_id") not in seen)
            ]
            if not kept and content:
                return False
            message["content"] = kept
        payload = record.get("payload") or {}
        if payload.get("type") in ("custom_tool_call_output", "function_call_output"):
            return payload.get("call_id") in seen
        return True

    kept = [r for r in window if keep(r)]

    if kind == "codex":
        # A Codex fixture states who wrote it. `session_meta` is the first record of every
        # rollout and names the `cli_version`, which is what `CodexRolloutFormat` is measured
        # against, so a window that starts later carries it along.
        if not any(r.get("type") == "session_meta" for r in kept):
            meta = next((r for r in records if r.get("type") == "session_meta"), None)
            if meta is not None:
                kept.insert(0, meta)
        # A `compacted` record carries the whole replacement history Codex handed the model —
        # 314 KB in one measured file. Three entries keep the shape at a fraction of the size.
        for record in kept:
            payload = record.get("payload") or {}
            history = payload.get("replacement_history")
            if record.get("type") == "compacted" and isinstance(history, list):
                payload["replacement_history"] = history[:3]

    return kept


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kind", choices=["claude", "codex"], required=True)
    parser.add_argument("--in", dest="source", required=True)
    parser.add_argument("--out", dest="destination", required=True)
    parser.add_argument("--max-records", type=int, default=120)
    args = parser.parse_args()

    with open(args.source, errors="replace") as handle:
        records = list(claude_records(handle))

    window = pick_window(records, args.kind, args.max_records)
    if not window:
        sys.exit(f"No usable records in {args.source}")

    with open(args.destination, "w") as handle:
        for record in window:
            handle.write(json.dumps(scrub(record), separators=(",", ":")) + "\n")

    print(f"{args.destination}: {len(window)} records from {len(records)}")


if __name__ == "__main__":
    main()
