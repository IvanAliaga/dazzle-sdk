#!/usr/bin/env python3
# Copyright 2026 Ivan Aliaga <ivan.aliaga@urp.edu.pe>
# SPDX-License-Identifier: Apache-2.0
#
# Sample-test report validator. Invoked by the bash test harnesses
# after a successful install+launch to confirm the JSON report
# produced on device matches the EXPECTED BEHAVIOUR of the sample,
# not just `status == "pass"`. A run can land with status=pass on a
# crash-silenced path (empty tool reply, cast failure inside the tool
# impl, scripted LLM reply that does not actually depend on the tool
# payload) and we would still call the test green — this module
# catches that.
#
# Usage:
#   python3 validate_sample_report.py <sample_name> <path/to/report.json>
#
# Exits 0 on PASS (all assertions hold), 1 on FAIL (one or more
# assertions violated, diagnostic printed to stderr).

import json
import re
import sys
from typing import Any, Callable, List, Tuple


# The native iOS harness writes camelCase keys (Codable default) while
# every other platform writes snake_case. We normalise once at load
# time so the assertion predicates stay readable.
_CAMEL_TO_SNAKE = {
    "sampleName": "sample_name",
    "elapsedMs": "elapsed_ms",
    "turnCount": "turn_count",
    "userTurns": "user_turns",
    "assistantTurns": "assistant_turns",
    "toolTurns": "tool_turns",
    "llmCallCount": "llm_call_count",
    "lastAssistantText": "last_assistant_text",
    "lastToolText": "last_tool_text",
}


def _is_json_array_of_objects(s: str) -> bool:
    """True when `s` parses as a JSON array whose every element is a
    dict. Catches silent on-the-wire truncation that would otherwise
    slip past substring-match assertions."""
    if not s:
        return False
    try:
        v = json.loads(s)
    except Exception:
        return False
    if not isinstance(v, list):
        return False
    return all(isinstance(e, dict) for e in v)


def load_report(path: str) -> dict:
    with open(path, "r") as f:
        raw = json.load(f)
    # Merge both conventions so predicates can read snake_case
    # regardless of which platform emitted the report.
    out = dict(raw)
    for camel, snake in _CAMEL_TO_SNAKE.items():
        if camel in raw and snake not in raw:
            out[snake] = raw[camel]
    return out


def assertions_for(name: str) -> List[Tuple[str, Callable[[dict], bool]]]:
    """Return a list of (description, predicate) for the given sample.

    Predicates take the parsed JSON report and return True when the
    invariant holds. Each sample validates both the "shape" of the
    conversation (turn counts cover the scripted user_inputs +
    llmScript we fed in) AND the CONTENT (tool outputs contain the
    dataset rows, final assistant text is non-empty / matches).

    Turn counts use `>=` because Dazzle persists the chat transcript
    across app launches by design — repeated test runs without a
    fresh install accumulate turns. The ABSOLUTE-MINIMUM shape still
    has to be there, and every content check is strict.
    """
    if name == "chat-memory":
        # Script: two substantive turns demonstrating conversational
        # persistence — user states their identity + project in turn 1,
        # the assistant acknowledges, then turn 2 asks the assistant to
        # recall both. The "remembered" final reply proves Dazzle
        # restored the prior turn's context on the fresh LLM call.
        return [
            ("status == pass",
                lambda d: d.get("status") == "pass"),
            ("no crash recorded",
                lambda d: d.get("error") in (None, "null", "")),
            ("user turns >= 2",
                lambda d: d.get("user_turns", 0) >= 2),
            ("assistant turns >= 2",
                lambda d: d.get("assistant_turns", 0) >= 2),
            ("tool turns == 0 (this sample has no tools)",
                lambda d: d.get("tool_turns", 1) == 0),
            ("llm_call_count >= 2",
                lambda d: d.get("llm_call_count", 0) >= 2),
            ("last assistant text is non-empty",
                lambda d: len(d.get("last_assistant_text", "")) > 0),
            ("final reply recalls the user's name (proves persistence)",
                lambda d: "ivan" in
                    d.get("last_assistant_text", "").lower()),
            ("final reply recalls the Dazzle project context",
                lambda d: "dazzle" in
                    d.get("last_assistant_text", "").lower()),
        ]

    if name == "chat-iot":
        # Script: analyst-style question over the IoT dataset —
        # "were there thermal anomalies in the last 800 minutes and
        # when?". LLM emits retrieve_anomalies(0, 800), tool returns
        # the real dataset rows (including the minute-195 28.5°C
        # spike), LLM grounds its final reply in those numbers.
        # Minimum shape user:>=1, assistant:>=2, tool:>=1.
        return [
            ("status == pass",
                lambda d: d.get("status") == "pass"),
            ("no crash recorded",
                lambda d: d.get("error") in (None, "null", "")),
            ("user turns >= 1",
                lambda d: d.get("user_turns", 0) >= 1),
            ("assistant turns >= 2 (tool-call + final reply)",
                lambda d: d.get("assistant_turns", 0) >= 2),
            ("tool turns >= 1 (retrieve_anomalies reply)",
                lambda d: d.get("tool_turns", 0) >= 1),
            ("llm_call_count >= 2",
                lambda d: d.get("llm_call_count", 0) >= 2),
            ("tool reply is non-empty (no empty [] / silent failure)",
                lambda d: len(d.get("last_tool_text", "")) > 4),
            ("tool reply is NOT a handler crash payload",
                lambda d: '"error"' not in d.get("last_tool_text", "")
                    or "anomaly_detected" in d.get("last_tool_text", "")),
            ("tool reply parses as JSON (catches silent byte-corruption)",
                lambda d: _is_json_array_of_objects(
                    d.get("last_tool_text", ""))),
            ("tool reply contains IoT rows (start_minute + anomaly_detected)",
                lambda d: (
                    "start_minute" in d.get("last_tool_text", "")
                    and "anomaly_detected" in d.get("last_tool_text", ""))),
            ("tool reply contains the minute-195 temp spike (28.5)",
                lambda d: "28.5" in d.get("last_tool_text", "")),
            ("tool reply preserves the ° degree symbol in the spike summary",
                lambda d: "°C" in d.get("last_tool_text", "")),
            ("final assistant text references a temperature spike",
                lambda d: re.search(
                    r"temperature|spike|anomal|thermal",
                    d.get("last_assistant_text", ""),
                    re.IGNORECASE) is not None),
            ("final assistant text mentions the 28.5 figure "
                "(grounded in tool output, not invented)",
                lambda d: "28.5" in d.get("last_assistant_text", "")),
            ("final assistant text mentions minute 195 (specific row from tool)",
                lambda d: "195" in d.get("last_assistant_text", "")),
        ]

    if name == "chat-kb":
        # Script: technical question about the Dazzle SDK itself —
        # "how does Dazzle compare to sqlite-vec on mobile?". LLM
        # issues search_kb over the FAQ corpus (HNSW_SQ8 vector
        # index), gets back FAQ rows with numerical benchmarks, and
        # emits a grounded comparative reply.
        return [
            ("status == pass",
                lambda d: d.get("status") == "pass"),
            ("no crash recorded",
                lambda d: d.get("error") in (None, "null", "")),
            ("user turns >= 1",
                lambda d: d.get("user_turns", 0) >= 1),
            ("assistant turns >= 2 (tool-call + final reply)",
                lambda d: d.get("assistant_turns", 0) >= 2),
            ("tool turns >= 1 (search_kb reply)",
                lambda d: d.get("tool_turns", 0) >= 1),
            ("llm_call_count >= 2",
                lambda d: d.get("llm_call_count", 0) >= 2),
            ("tool reply is non-empty",
                lambda d: len(d.get("last_tool_text", "")) > 4),
            ("tool reply parses as JSON (catches silent byte-corruption)",
                lambda d: _is_json_array_of_objects(
                    d.get("last_tool_text", ""))),
            ("tool reply references the Dazzle FAQ schema (faq-NNN ids)",
                lambda d: re.search(
                    r"faq-\d{3}", d.get("last_tool_text", "")) is not None),
            ("tool reply has answer + score fields per hit",
                lambda d: (
                    "\"answer\"" in d.get("last_tool_text", "")
                    and "\"score\"" in d.get("last_tool_text", ""))),
            ("final assistant text mentions Dazzle",
                lambda d: "dazzle" in
                    d.get("last_assistant_text", "").lower()),
            ("final assistant text mentions HNSW (the actual index algorithm)",
                lambda d: "hnsw" in
                    d.get("last_assistant_text", "").lower()),
            ("final assistant text compares against sqlite-vec",
                lambda d: "sqlite-vec" in
                    d.get("last_assistant_text", "").lower()),
        ]

    raise SystemExit(f"unknown sample {name!r}")


def main():
    if len(sys.argv) != 3:
        print("usage: validate_sample_report.py <sample> <report.json>",
              file=sys.stderr)
        sys.exit(2)
    name, path = sys.argv[1], sys.argv[2]
    data = load_report(path)

    failures = []
    for description, pred in assertions_for(name):
        try:
            ok = bool(pred(data))
        except Exception as e:
            ok = False
            description = f"{description} (raised {e!r})"
        if not ok:
            failures.append(description)

    if failures:
        print(f"\033[1;31m[validate]\033[0m {name}: "
              f"{len(failures)} assertion(s) failed",
              file=sys.stderr)
        for f in failures:
            print(f"  ✗ {f}", file=sys.stderr)
        print("\nreport:", file=sys.stderr)
        json.dump(data, sys.stderr, indent=2)
        print("", file=sys.stderr)
        sys.exit(1)
    print(f"\033[1;32m[validate]\033[0m {name}: all "
          f"{len(assertions_for(name))} assertions PASS",
          file=sys.stderr)


if __name__ == "__main__":
    main()
