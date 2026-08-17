#!/usr/bin/env python3
"""Mine local Claude/Codex histories for possible repository-guidance improvements.

The report is deliberately a private triage artifact, not an automatic prompt writer. It reads
only human and agent text records, excludes provider bookkeeping and subagent/guardian sessions,
deduplicates conversations copied between accounts, and writes no transcript data outside the
requested local output path.
"""

from __future__ import annotations

import argparse
import json
import re
from collections import Counter
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Optional


SHELL_PROFILES = (
    ".zshenv",
    ".zprofile",
    ".zshrc",
    ".bashrc",
    ".bash_profile",
    ".profile",
)
MAX_SHELL_PROFILE_BYTES = 2 * 1024 * 1024

GENERATED_USER_PREFIXES = (
    "<available-deferred-tools>",
    "<command-args>",
    "<command-message>",
    "<command-name>",
    "<fork-boilerplate>",
    "<ide_opened_file>",
    "<local-command-caveat>",
    "<local-command-stdout>",
    "<session-message",
    "<system-reminder>",
    "<task-notification>",
    "<teammate-message",
    "[Cross-session message",
    "[Session watch",
    "The following is the Codex agent history",
    "This session is being continued from a previous conversation that ran out of context.",
    "You are the settings search of Threading",
)

CORRECTION_SIGNALS = (
    (8, re.compile(r"^\s*(?:no|nope|stop|wait|hold on)\b", re.IGNORECASE)),
    (8, re.compile(r"\bnot what i (?:asked|meant|wanted)\b", re.IGNORECASE)),
    (
        7,
        re.compile(
            r"\byou (?:didn't|did not|haven't|have not|forgot|missed|ignored|"
            r"shouldn't|should not|broke)\b",
            re.IGNORECASE,
        ),
    ),
    (7, re.compile(r"\bwhy did (?:you|we)\b", re.IGNORECASE)),
    (
        7,
        re.compile(
            r"\b(?:that|this|it)(?:'s| is) (?:wrong|not right|still wrong|broken|not correct)\b",
            re.IGNORECASE,
        ),
    ),
    (6, re.compile(r"\bi (?:asked|said|told you)\b", re.IGNORECASE)),
    (5, re.compile(r"\b(?:do you not|don't you|don’t you)\b", re.IGNORECASE)),
    (
        5,
        re.compile(
            r"\bstill (?:doesn't|does not|isn't|is not|wrong|broken|fails|failing)\b",
            re.IGNORECASE,
        ),
    ),
    (4, re.compile(r"\bagain\b", re.IGNORECASE)),
)

GUIDANCE_SIGNAL = re.compile(
    r"(?:our|the|update|change|edit|add to) (?:agents?\.md|claude\.md)|"
    r"agent files?|add (?:a )?rule|add .*guidance|"
    r"single source of truth|root cause|band.?aid|hard to get wrong|monkey patch|"
    r"proper abstractions?|fully customis|always center by ink|performance as key",
    re.IGNORECASE,
)

THEME_SIGNALS = {
    "Extension/customization": re.compile(
        r"\b(?:extension|extensions|customis|configurable|host.?owned|host.?only)\b",
        re.IGNORECASE,
    ),
    "Visual evidence": re.compile(
        r"\b(?:screenshot|render|visual|pixel|spacing|alignment|balanced|theme|chrome)\b",
        re.IGNORECASE,
    ),
    "Completion/verification": re.compile(
        r"\b(?:finish|complete|test|verify|verification|build|regression|make sure)\b",
        re.IGNORECASE,
    ),
    "Root cause/structure": re.compile(
        r"\b(?:root cause|band.?aid|structural|single source|abstract|provider.?neutral|fragile)\b",
        re.IGNORECASE,
    ),
    "Performance/scaling": re.compile(
        r"\b(?:performance|slow|latency|memory|scale|scaling|unbounded|profil)\w*\b",
        re.IGNORECASE,
    ),
    "Agent guidance": re.compile(
        r"\b(?:agents?\.md|claude\.md|agent files?|instruction|guidance|add a rule)\b",
        re.IGNORECASE,
    ),
}

ALIAS_DECLARATION = re.compile(r"^\s*alias\s+([A-Za-z_][A-Za-z0-9_-]*)=(.*)$")
CONFIG_ASSIGNMENT = re.compile(
    r"\b(CLAUDE_CONFIG_DIR|CODEX_HOME)=(?:\"([^\"]+)\"|'([^']+)'|([^\s;]+))"
)
AMBIENT_BROWSER_CONTEXT = re.compile(
    r"<in-app-browser-context\b.*?</in-app-browser-context>",
    re.DOTALL,
)
USER_REQUEST_SECTION = re.compile(
    r"## My request(?: for Codex)?:\s*(.*)",
    re.DOTALL | re.IGNORECASE,
)
BROWSER_COMMENT = re.compile(
    r"Comment:\s*(.*?)(?=\s*## User Comment|\s*<in-app-browser-context|"
    r"\s*## My request|$)",
    re.DOTALL,
)


@dataclass(frozen=True)
class Profile:
    provider: str
    root: Path
    aliases: tuple[str, ...]

@dataclass(frozen=True)
class UserTurn:
    text: str
    timestamp: str
    previous_agent_text: str


@dataclass
class Conversation:
    provider: str
    profile: Profile
    session_id: str
    path: Path
    title: str
    user_turns: list[UserTurn] = field(default_factory=list)
    first_timestamp: str = ""
    last_timestamp: str = ""
    size: int = 0


@dataclass
class ScanStats:
    claude_transcripts: int = 0
    codex_project_rollouts: int = 0
    codex_subagent_rollouts: int = 0


@dataclass
class Audit:
    project: Path
    profiles: list[Profile]
    conversations: list[Conversation]
    stats: ScanStats

    @property
    def user_turn_count(self) -> int:
        return sum(len(conversation.user_turns) for conversation in self.conversations)


@dataclass(frozen=True)
class Candidate:
    score: int
    conversation: Conversation
    turn_index: int
    turn: UserTurn


def canonical(path: Path) -> Path:
    return path.expanduser().resolve(strict=False)


def expand_home(value: str, home: Path) -> Path:
    expanded = value.replace("${HOME}", str(home)).replace("$HOME", str(home))
    if expanded == "~":
        expanded = str(home)
    elif expanded.startswith("~/"):
        expanded = str(home / expanded[2:])
    return canonical(Path(expanded))


def shell_aliases(home: Path) -> dict[tuple[str, Path], set[str]]:
    """Read config-routing aliases without sourcing or executing a shell profile."""
    routes_by_alias: dict[str, tuple[str, Path]] = {}
    for name in SHELL_PROFILES:
        profile = home / name
        if not profile.is_file():
            continue
        try:
            if profile.stat().st_size > MAX_SHELL_PROFILE_BYTES:
                continue
            lines = profile.read_text(encoding="utf-8").splitlines()
        except (OSError, UnicodeError):
            continue
        for line in lines:
            declaration = ALIAS_DECLARATION.match(line)
            if declaration is None:
                continue
            alias_name = declaration.group(1)
            body = declaration.group(2).strip()
            if (
                len(body) >= 2
                and body[0] in ("'", '"')
                and body[-1] == body[0]
            ):
                body = body[1:-1]
            assignment = CONFIG_ASSIGNMENT.search(body)
            if assignment is None:
                continue
            variable = assignment.group(1)
            raw_path = next(
                value for value in assignment.groups()[1:] if value is not None
            )
            provider = "Claude" if variable == "CLAUDE_CONFIG_DIR" else "Codex"
            routes_by_alias[alias_name] = (provider, expand_home(raw_path, home))

    result: dict[tuple[str, Path], set[str]] = {}
    for alias_name, route in routes_by_alias.items():
        result.setdefault(route, set()).add(alias_name)
    return result


def is_claude_science_root(path: Path) -> bool:
    return (
        (path / "install-id").exists()
        and (path / "runtime").is_dir()
        and (path / "orgs").is_dir()
    )


def discover_profiles(home: Path) -> list[Profile]:
    home = canonical(home)
    aliases = shell_aliases(home)
    profiles: list[Profile] = []

    claude_roots = [home / ".claude"] + sorted(home.glob(".claude-*"))
    codex_roots = [home / ".codex"] + sorted(home.glob(".codex-*"))

    seen: set[tuple[str, Path]] = set()
    for provider, roots, store_name in (
        ("Claude", claude_roots, "projects"),
        ("Codex", codex_roots, "sessions"),
    ):
        for root in roots:
            root = canonical(root)
            key = (provider, root)
            if key in seen or not (root / store_name).is_dir():
                continue
            if provider == "Claude" and is_claude_science_root(root):
                continue
            seen.add(key)
            profiles.append(
                Profile(
                    provider=provider,
                    root=root,
                    aliases=tuple(sorted(aliases.get(key, set()))),
                )
            )
    return profiles


def claude_project_slug(path: str) -> str:
    """Encode a path per Claude's measured UTF-16-code-unit directory convention."""
    encoded = path.encode("utf-16-le", errors="surrogatepass")
    output: list[str] = []
    for index in range(0, len(encoded), 2):
        unit = encoded[index] | (encoded[index + 1] << 8)
        character = chr(unit)
        output.append(character if character.isascii() and character.isalnum() else "-")
    return "".join(output)


def record_text(content: object) -> Optional[str]:
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return None
    values = [
        item.get("text", "")
        for item in content
        if isinstance(item, dict) and item.get("type") in ("text", "input_text")
    ]
    text = "\n".join(value for value in values if value)
    return text or None


def clean_human_text(value: object) -> Optional[str]:
    if not isinstance(value, str):
        return None
    text = value.strip()
    if not text or text.startswith(GENERATED_USER_PREFIXES):
        return None

    text = AMBIENT_BROWSER_CONTEXT.sub("", text).strip()
    request = USER_REQUEST_SECTION.search(text)
    if request is not None:
        text = request.group(1).strip()
    if "# Browser comments:" in text:
        comments = [match.strip() for match in BROWSER_COMMENT.findall(text)]
        if comments:
            text = " | ".join(comments)
    text = re.sub(r"\s+", " ", text).strip()
    if not text or text.startswith(GENERATED_USER_PREFIXES):
        return None
    return text


def timestamps(record: dict, first: str, last: str) -> tuple[str, str]:
    timestamp = record.get("timestamp")
    if not isinstance(timestamp, str) or not timestamp:
        return first, last
    return first or timestamp, max(last, timestamp)


def parse_claude_transcript(
    path: Path,
    profile: Profile,
    project: Path,
    since: Optional[str],
) -> Optional[Conversation]:
    user_turns: list[UserTurn] = []
    agent_text: list[str] = []
    session_id = path.stem
    title = ""
    first_timestamp = ""
    last_timestamp = ""
    project_string = str(project)

    try:
        with path.open("rb") as handle:
            for raw in handle:
                if not any(
                    marker in raw
                    for marker in (
                        b'"type":"user"',
                        b'"type":"assistant"',
                        b'"type":"ai-title"',
                    )
                ):
                    continue
                try:
                    record = json.loads(raw)
                except (json.JSONDecodeError, UnicodeDecodeError):
                    continue
                kind = record.get("type")
                if kind not in ("user", "assistant", "ai-title"):
                    continue
                cwd = record.get("cwd")
                if isinstance(cwd, str) and str(canonical(Path(cwd))) != project_string:
                    continue
                first_timestamp, last_timestamp = timestamps(
                    record, first_timestamp, last_timestamp
                )
                value = record.get("sessionId")
                if isinstance(value, str) and value:
                    session_id = value
                if kind == "ai-title":
                    value = record.get("aiTitle")
                    if isinstance(value, str) and value:
                        title = value
                    continue
                if record.get("isSidechain") is True:
                    continue
                message = record.get("message")
                if not isinstance(message, dict):
                    continue
                if kind == "assistant":
                    text = record_text(message.get("content"))
                    if text:
                        agent_text.append(text.strip())
                    continue
                if record.get("isMeta") is True or message.get("role") != "user":
                    continue
                text = clean_human_text(record_text(message.get("content")))
                timestamp = record.get("timestamp") or ""
                if text is None:
                    continue
                previous_agent_text = "\n".join(agent_text[-4:])[-2_000:]
                agent_text = []
                if since and timestamp and timestamp[:10] < since:
                    continue
                user_turns.append(
                    UserTurn(
                        text=text,
                        timestamp=timestamp,
                        previous_agent_text=previous_agent_text,
                    )
                )
    except OSError:
        return None

    if not user_turns:
        return None
    return Conversation(
        provider="Claude",
        profile=profile,
        session_id=session_id,
        path=path,
        title=title or user_turns[0].text[:120],
        user_turns=user_turns,
        first_timestamp=first_timestamp,
        last_timestamp=last_timestamp,
        size=path.stat().st_size,
    )


def codex_metadata(path: Path) -> Optional[dict]:
    try:
        with path.open("rb") as handle:
            first = handle.readline()
        record = json.loads(first)
    except (OSError, json.JSONDecodeError, UnicodeDecodeError):
        return None
    if record.get("type") != "session_meta" or not isinstance(record.get("payload"), dict):
        return None
    return record["payload"]


def is_codex_subagent(metadata: dict) -> bool:
    if metadata.get("thread_source") == "subagent":
        return True
    source = metadata.get("source")
    return isinstance(source, dict) and "subagent" in source


def parse_codex_rollout(
    path: Path,
    profile: Profile,
    metadata: dict,
    since: Optional[str],
) -> Optional[Conversation]:
    user_turns: list[UserTurn] = []
    agent_text: list[str] = []
    first_timestamp = ""
    last_timestamp = ""
    session_id = metadata.get("id") or path.stem

    try:
        with path.open("rb") as handle:
            first_record = json.loads(handle.readline())
            first_timestamp, last_timestamp = timestamps(first_record, "", "")
            for raw in handle:
                if b'"type":"event_msg"' not in raw:
                    continue
                try:
                    record = json.loads(raw)
                except (json.JSONDecodeError, UnicodeDecodeError):
                    continue
                if record.get("type") != "event_msg":
                    continue
                payload = record.get("payload")
                if not isinstance(payload, dict):
                    continue
                first_timestamp, last_timestamp = timestamps(
                    record, first_timestamp, last_timestamp
                )
                kind = payload.get("type")
                if kind == "agent_message":
                    value = payload.get("message")
                    if isinstance(value, str) and value.strip():
                        agent_text.append(value.strip())
                    continue
                if kind != "user_message":
                    continue
                text = clean_human_text(payload.get("message"))
                timestamp = record.get("timestamp") or ""
                if text is None:
                    continue
                previous_agent_text = "\n".join(agent_text[-4:])[-2_000:]
                agent_text = []
                if since and timestamp and timestamp[:10] < since:
                    continue
                user_turns.append(
                    UserTurn(
                        text=text,
                        timestamp=timestamp,
                        previous_agent_text=previous_agent_text,
                    )
                )
    except (OSError, json.JSONDecodeError, UnicodeDecodeError):
        return None

    if not user_turns:
        return None
    return Conversation(
        provider="Codex",
        profile=profile,
        session_id=str(session_id),
        path=path,
        title=user_turns[0].text[:120],
        user_turns=user_turns,
        first_timestamp=first_timestamp,
        last_timestamp=last_timestamp,
        size=path.stat().st_size,
    )


def conversation_rank(conversation: Conversation) -> tuple[int, str, int]:
    return (
        len(conversation.user_turns),
        conversation.last_timestamp,
        conversation.size,
    )


def deduplicated(conversations: Iterable[Conversation]) -> list[Conversation]:
    result: dict[tuple[str, str], Conversation] = {}
    for conversation in conversations:
        key = (conversation.provider, conversation.session_id)
        existing = result.get(key)
        if existing is None or conversation_rank(conversation) > conversation_rank(existing):
            result[key] = conversation
    return sorted(
        result.values(),
        key=lambda conversation: (conversation.last_timestamp, conversation.session_id),
    )


def audit_project(project: Path, home: Path, since: Optional[str] = None) -> Audit:
    project = canonical(project)
    profiles = discover_profiles(home)
    stats = ScanStats()
    conversations: list[Conversation] = []
    slug = claude_project_slug(str(project))

    for profile in profiles:
        if profile.provider == "Claude":
            directory = profile.root / "projects" / slug
            if not directory.is_dir():
                continue
            for path in sorted(directory.glob("*.jsonl")):
                stats.claude_transcripts += 1
                conversation = parse_claude_transcript(path, profile, project, since)
                if conversation is not None:
                    conversations.append(conversation)
            continue

        sessions = profile.root / "sessions"
        for path in sorted(sessions.rglob("*.jsonl")):
            metadata = codex_metadata(path)
            if metadata is None:
                continue
            cwd = metadata.get("cwd")
            if not isinstance(cwd, str) or canonical(Path(cwd)) != project:
                continue
            stats.codex_project_rollouts += 1
            if is_codex_subagent(metadata):
                stats.codex_subagent_rollouts += 1
                continue
            conversation = parse_codex_rollout(path, profile, metadata, since)
            if conversation is not None:
                conversations.append(conversation)

    return Audit(
        project=project,
        profiles=profiles,
        conversations=deduplicated(conversations),
        stats=stats,
    )


def correction_score(text: str, turn_index: int) -> int:
    score = sum(weight for weight, pattern in CORRECTION_SIGNALS if pattern.search(text))
    if turn_index == 0:
        score -= 3
    if len(text) > 8_000:
        score -= 3
    return score


def correction_candidates(audit: Audit) -> list[Candidate]:
    candidates: list[Candidate] = []
    for conversation in audit.conversations:
        for index, turn in enumerate(conversation.user_turns):
            score = correction_score(turn.text, index)
            if score >= 5:
                candidates.append(Candidate(score, conversation, index, turn))
    return sorted(
        candidates,
        key=lambda candidate: (
            candidate.score,
            candidate.turn.timestamp,
            candidate.conversation.session_id,
        ),
        reverse=True,
    )


def guidance_candidates(audit: Audit) -> list[Candidate]:
    candidates: list[Candidate] = []
    seen: set[tuple[str, str, str]] = set()
    for conversation in audit.conversations:
        for index, turn in enumerate(conversation.user_turns):
            if not GUIDANCE_SIGNAL.search(turn.text):
                continue
            key = (conversation.provider, conversation.session_id, turn.text)
            if key in seen:
                continue
            seen.add(key)
            candidates.append(Candidate(0, conversation, index, turn))
    return sorted(
        candidates,
        key=lambda candidate: (
            candidate.turn.timestamp,
            candidate.conversation.session_id,
        ),
        reverse=True,
    )


def excerpt(text: str, limit: int = 700) -> str:
    value = re.sub(r"\s+", " ", text).strip()
    if len(value) <= limit:
        return value
    return value[: limit - 1].rstrip() + "…"


def markdown_cell(value: str) -> str:
    return value.replace("|", "\\|").replace("\n", " ")


def candidate_markdown(candidate: Candidate, include_score: bool) -> str:
    conversation = candidate.conversation
    date = candidate.turn.timestamp[:10] or "unknown date"
    identity = conversation.session_id[:8]
    score = f", score {candidate.score}" if include_score else ""
    lines = [
        f"### {conversation.provider} {identity} · {date} · turn {candidate.turn_index + 1}{score}",
        "",
        f"> {excerpt(candidate.turn.text)}",
    ]
    if candidate.turn.previous_agent_text:
        lines.extend(
            [
                "",
                "Previous agent text:",
                "",
                f"> {excerpt(candidate.turn.previous_agent_text, 420)}",
            ]
        )
    return "\n".join(lines)


def render_report(audit: Audit, max_candidates: int = 60) -> str:
    by_provider = Counter(
        conversation.provider for conversation in audit.conversations
    )
    turns_by_provider = Counter()
    for conversation in audit.conversations:
        turns_by_provider[conversation.provider] += len(conversation.user_turns)

    corrections = correction_candidates(audit)
    guidance = guidance_candidates(audit)
    all_text = [
        turn.text
        for conversation in audit.conversations
        for turn in conversation.user_turns
    ]
    theme_counts = {
        name: sum(1 for text in all_text if pattern.search(text))
        for name, pattern in THEME_SIGNALS.items()
    }

    generated = datetime.now(timezone.utc).isoformat(timespec="seconds")
    lines = [
        "# Agent Feedback Audit",
        "",
        "> Private local triage artifact. Do not commit this report or its transcript excerpts.",
        "",
        f"Generated: `{generated}`  ",
        f"Project cwd: `{audit.project}`",
        "",
        "## Corpus",
        "",
        "| Provider | Deduplicated conversations | Human user turns |",
        "|---|---:|---:|",
    ]
    for provider in ("Claude", "Codex"):
        lines.append(
            f"| {provider} | {by_provider[provider]} | {turns_by_provider[provider]} |"
        )
    lines.extend(
        [
            f"| **Total** | **{len(audit.conversations)}** | **{audit.user_turn_count}** |",
            "",
            f"Claude transcript files inspected: {audit.stats.claude_transcripts}.  ",
            f"Codex project rollouts found: {audit.stats.codex_project_rollouts}; "
            f"{audit.stats.codex_subagent_rollouts} subagent/guardian rollouts excluded.  ",
            f"High-confidence correction candidates: {len(corrections)}.  ",
            f"Explicit guidance/process candidates: {len(guidance)}.",
            "",
            "## Profiles and aliases",
            "",
            "Aliases are read as text from shell profiles; the audit never sources or executes them.",
            "",
            "| Provider | Config root | Alias labels |",
            "|---|---|---|",
        ]
    )
    for profile in audit.profiles:
        aliases = ", ".join(profile.aliases)
        if not aliases:
            aliases = (
                f"{profile.provider} (default executable)"
                if profile.root.name in (".claude", ".codex")
                else "no routing alias found"
            )
        lines.append(
            f"| {profile.provider} | `{markdown_cell(str(profile.root))}` | "
            f"{markdown_cell(aliases)} |"
        )

    lines.extend(
        [
            "",
            "## Triage themes",
            "",
            "Counts overlap and are search signals, not semantic verdicts.",
            "",
            "| Theme | Matching human turns |",
            "|---|---:|",
        ]
    )
    for name, count in sorted(theme_counts.items(), key=lambda item: item[1], reverse=True):
        lines.append(f"| {name} | {count} |")

    lines.extend(["", "## High-confidence correction candidates", ""])
    if corrections:
        lines.append(
            "These are lexical candidates for human review; a correction is not automatically a "
            "repository rule."
        )
        for candidate in corrections[:max_candidates]:
            lines.extend(["", candidate_markdown(candidate, include_score=True)])
    else:
        lines.append("No candidates matched the current high-confidence signals.")

    lines.extend(["", "## Explicit guidance/process candidates", ""])
    if guidance:
        lines.append(
            "Promote only repeated, future-actionable behavior. Prefer an owning test, typed "
            "boundary or lint over another prose rule."
        )
        for candidate in guidance[:max_candidates]:
            lines.extend(["", candidate_markdown(candidate, include_score=False)])
    else:
        lines.append("No explicit guidance/process candidates matched.")

    lines.extend(
        [
            "",
            "## Review checklist",
            "",
            "1. Group repeated failures by the earliest decision that would have prevented them.",
            "2. Check whether the rule already exists and whether agents are merely routed to the wrong document.",
            "3. Put cross-cutting guidance in `CLAUDE.md`; put subsystem behavior in its architecture document.",
            "4. Prefer code ownership, a typed registry, a focused test or a boundary lint when the rule is enforceable.",
            "5. Re-run this audit after an instruction change and compare representative failures before adding more prose.",
            "",
        ]
    )
    return "\n".join(lines)


def validate_since(value: Optional[str]) -> Optional[str]:
    if value is None:
        return None
    try:
        datetime.strptime(value, "%Y-%m-%d")
    except ValueError as error:
        raise argparse.ArgumentTypeError("--since must be YYYY-MM-DD") from error
    return value


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Create a private local audit of Claude/Codex feedback for one project cwd."
    )
    parser.add_argument(
        "project",
        nargs="?",
        type=Path,
        default=Path.cwd(),
        help="Exact project cwd recorded by the providers (default: current directory).",
    )
    parser.add_argument(
        "--home",
        type=Path,
        default=Path.home(),
        help="Home directory containing provider config roots and shell profiles.",
    )
    parser.add_argument(
        "--since",
        type=validate_since,
        help="Include human turns on or after YYYY-MM-DD.",
    )
    parser.add_argument(
        "--max-candidates",
        type=int,
        default=60,
        help="Maximum candidates to show in each report section (default: 60).",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="Report path (default: <project>/.build/agent-feedback/report.md).",
    )
    parser.add_argument(
        "--stdout",
        action="store_true",
        help="Print the report instead of writing the default private artifact.",
    )
    arguments = parser.parse_args()
    if arguments.max_candidates < 0:
        parser.error("--max-candidates must be non-negative")

    audit = audit_project(arguments.project, arguments.home, arguments.since)
    report = render_report(audit, arguments.max_candidates)
    if arguments.stdout:
        print(report)
        return

    output = arguments.output or (
        canonical(arguments.project) / ".build" / "agent-feedback" / "report.md"
    )
    output = canonical(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(report, encoding="utf-8")
    print(output)


if __name__ == "__main__":
    main()
