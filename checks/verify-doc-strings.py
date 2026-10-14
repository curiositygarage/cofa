#!/usr/bin/env python3
"""checks/verify-doc-strings.py — every REQUIREDCHECK line a doc promises must be printed by code.

A KEYS-REQUIRED "Announcement rule" hands the reader an exact line they are
supposed to see when something is missing. If no shell or Python file prints
that string, the doc is describing a message that does not exist — the reader
waits for a line that never comes.

That is not hypothetical: `a2a-mesh/KEYS-REQUIRED.md` promised
`REQUIREDCHECK my_agent_id` while the component's verifier prints
`REQUIREDCHECK a2a-mesh-config`. Found by external review, round 9.

Rule: every `REQUIREDCHECK <name>` in any markdown file must appear as the
literal string `REQUIREDCHECK <name>` in at least one shell or Python file.
Templates are exempt and counted separately: a promise written as
`REQUIREDCHECK <key-name>` is a placeholder for the author, not a literal claim.

Exit codes
  0  every promised REQUIREDCHECK string is printed somewhere
  1  at least one UNPRINTED promise
  2  usage / internal error
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SKIP_DIRS = {".git", "__pycache__", ".venv", "node_modules"}
SELF = {Path(__file__).resolve().name}
CODE_SUFFIX = {".sh", ".bash", ".py"}
DOC_RE = re.compile(r"REQUIREDCHECK\s+(\S+?)(?=[:\s]|$)")


def walk() -> list[Path]:
    out = []
    for p in ROOT.rglob("*"):
        if any(part in SKIP_DIRS for part in p.parts):
            continue
        if p.is_file() and p.name not in SELF:
            out.append(p)
    return sorted(out)


def main() -> int:
    if len(sys.argv) > 1:
        print(f"usage: {sys.argv[0]}", file=sys.stderr)
        return 2

    files = walk()
    docs = [p for p in files if p.suffix.lower() == ".md"]
    code_blob = []
    for p in files:
        if p.suffix.lower() not in CODE_SUFFIX:
            continue
        try:
            code_blob.append(p.read_text(encoding="utf-8", errors="replace"))
        except OSError:
            continue
    haystack = "\n".join(code_blob)

    promised: dict[str, set[str]] = {}
    placeholders = 0
    for d in docs:
        try:
            text = d.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for raw in DOC_RE.findall(text):
            token = raw.rstrip(".,;")
            if token.startswith("<"):
                placeholders += 1
                continue
            promised.setdefault(token, set()).add(str(d.relative_to(ROOT)))

    unprinted = []
    for name in sorted(promised):
        where = ", ".join(sorted(promised[name]))
        if f"REQUIREDCHECK {name}" in haystack:
            print(f"PRINTED    REQUIREDCHECK {name}  (promised in: {where})")
        else:
            unprinted.append(name)
            print(f"UNPRINTED  REQUIREDCHECK {name}  (promised in: {where})")

    print(f"\n{len(promised)} REQUIREDCHECK name(s) promised in markdown, "
          f"{len(unprinted)} unprinted, {placeholders} template placeholder(s)")
    if unprinted:
        print("\nUNPRINTED means a doc promises a line no shell/Python file prints. Align the doc "
              "to the string the component's verifier actually emits.")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
