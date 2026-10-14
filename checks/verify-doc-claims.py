#!/usr/bin/env python3
"""checks/verify-doc-claims.py — doc-vs-code consistency gate step (two rules).

RULE 1 — names. Every ENV-VAR-looking name (ALL_CAPS with at least one
underscore, e.g. `A2A_PEER_ENDPOINTS`) that appears in a markdown file must be
REFERENCED by at least one non-doc file in the tree. A doc that names a variable
no code references is a claim a reader cannot act on — it is how
`A2A_PEER_ENDPOINTS` survived two rounds of review while nothing in the tree
read that name.

Referenced means one of three code-level classes, checked in this order:

  READ     the tree reads it:  os.environ["NAME"] / .get("NAME") /
           .setdefault("NAME" / os.getenv("NAME") / $NAME or ${NAME...} in a shell script
  LITERAL  a .py/.sh/.js file compares or emits it as a string literal: "NAME"
  PATH     it is a filename stem the code builds or names: NAME.md, NAME.txt

A MENTION is not a reference (tightened in round 9, external review). A name can
sit in a script comment, or in a CI service definition (`POSTGRES_PASSWORD` in a
workflow `env:`) while no file in this tree reads it. Four planted shapes prove
the difference: comment-only and CI-YAML-only are BACKED under "appears
somewhere" and UNBACKED under this rule; a shell read and an os.environ.get are
READ under both.

Why three classes and not just READ: the name pattern is ALL_CAPS_WITH_AN_
UNDERSCORE, which also matches tokens that are not variables at all — A2A
protocol enum values (`INPUT_REQUIRED`, read by the client as a frozenset of
string literals) and generated filenames (`LAST_TASK.md`). Forcing those through
a read-only rule would either fail the gate on true docs or push five names onto
the allowlist and hollow out the rule. LITERAL and PATH are still code-level
references: a comment or a YAML setting satisfies neither.

RULE 2 — wording. Same class of claim, about what the software IS. The one
canonical phrase for the client is:

    A2A-style JSON-RPC client (v1.0 `SendMessage` dialect)

An unqualified shape — `A2A v1.0 client`, `v1.0 mesh client`, `v1.0 peer
messaging` — fails anywhere outside a patch file. A .patch/.diff quotes the old
text on purpose and must keep quoting it verbatim, so it is exempt.

Non-goals: prose truth stays with human review. This check is deliberately
mechanical: it can only be wrong in the direction of reporting a claim that
exists but is not wired (which is the failure we want loud), never of blessing
a claim that does not exist.

Exit codes
  0  every doc-named variable is referenced by a non-doc file, no unqualified wording
  1  at least one UNBACKED name or BANNED-WORDING hit
  2  usage / internal error (including a malformed allowlist entry)

Allowlist: checks/doc-claims-allow.txt — `NAME  path` per line, `#` comments.
Entries are FILE-SCOPED: allowing `EXPECTED_SHA256` in a reader-authored
download.sh example inside policy-cel/downloads/README.md must not excuse the
same name appearing as a COFA claim in any other file. The path is required; an
entry without one is an error, not a global pass. Reserve the file for names
that are doc-only BY DESIGN — a placeholder the reader creates themselves.
Anything else should be fixed in the doc instead.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SKIP_DIRS = {".git", "__pycache__", ".venv", "node_modules"}
# This checker must not back the names it audits: its own comments name one by example.
SELF = {Path(__file__).resolve().name, "doc-claims-allow.txt"}
NAME_RE = re.compile(r"\b[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+\b")
ALLOW = ROOT / "checks" / "doc-claims-allow.txt"

CANONICAL = "A2A-style JSON-RPC client (v1.0 `SendMessage` dialect)"
BANNED = ("A2A v1.0 client", "v1.0 mesh client", "v1.0 peer messaging")
# A patch quotes the pre-fix text verbatim; it is evidence, not a claim.
PATCH_SUFFIXES = (".patch", ".diff")


def walk() -> list[Path]:
    out = []
    for p in ROOT.rglob("*"):
        if any(part in SKIP_DIRS for part in p.parts):
            continue
        if p.is_file() and p.name not in SELF:
            out.append(p)
    return sorted(out)


def classify(name: str, blob: str) -> str | None:
    """The strongest code-level class that references `name` in the non-doc tree, or None."""
    n = re.escape(name)
    classes = (
        (
            "READ",
            (
                r'os\.environ\s*\[\s*[\'"]' + n + r'[\'"]',
                r'os\.environ\.get\s*\(\s*[\'"]' + n + r'[\'"]',
                r'os\.environ\.setdefault\s*\(\s*[\'"]' + n + r'[\'"]',
                r'os\.getenv\s*\(\s*[\'"]' + n + r'[\'"]',
                r'\$\{?' + n + r'\b',
            ),
        ),
        ("LITERAL", (r'[\'"]' + n + r'[\'"]',)),
        ("PATH", (r'\b' + n + r'\.[A-Za-z0-9]',)),
    )
    for label, patterns in classes:
        if any(re.search(p, blob) for p in patterns):
            return label
    return None


def is_patch(p: Path) -> bool:
    return p.name.endswith(PATCH_SUFFIXES) or ".patch." in p.name


def load_allow() -> dict[str, set[str]]:
    """name -> set of doc paths it is allowed in (file-scoped, path required)."""
    allow: dict[str, set[str]] = {}
    if not ALLOW.is_file():
        return allow
    for lineno, raw in enumerate(ALLOW.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) < 2:
            raise ValueError(
                f"{ALLOW.relative_to(ROOT)}:{lineno}: entry {parts[0]!r} has no path — "
                "allowlist entries are file-scoped (`NAME  path/to/file.md`)."
            )
        allow.setdefault(parts[0], set()).add(parts[1].lstrip("./"))
    return allow


def main() -> int:
    if len(sys.argv) > 1:
        print(f"usage: {sys.argv[0]}", file=sys.stderr)
        return 2

    try:
        allow = load_allow()
    except ValueError as exc:
        print(f"allowlist error: {exc}", file=sys.stderr)
        return 2

    files = walk()
    docs = [p for p in files if p.suffix.lower() == ".md"]
    code = [p for p in files if p.suffix.lower() != ".md"]

    # Read non-doc content once (small tree; keeps this O(1) file reads per name).
    code_blob = []
    for p in code:
        try:
            code_blob.append(p.read_text(encoding="utf-8", errors="replace"))
        except OSError:
            continue
    haystack = "\n".join(code_blob)

    seen: dict[str, set[str]] = {}
    for d in docs:
        try:
            text = d.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for name in NAME_RE.findall(text):
            seen.setdefault(name, set()).add(str(d.relative_to(ROOT)))

    unbacked = []
    allowed_count = 0
    for name in sorted(seen):
        where = ", ".join(sorted(seen[name]))
        scopes = allow.get(name)
        if scopes and seen[name] <= scopes:
            allowed_count += 1
            print(f"ALLOWED   {name}  (allowed in: {', '.join(sorted(scopes))})")
            continue
        if scopes:
            out_of_scope = ", ".join(sorted(seen[name] - scopes))
            unbacked.append(name)
            print(f"UNBACKED  {name}  (named in: {where}; allowlisted only for "
                  f"{', '.join(sorted(scopes))} — out of scope: {out_of_scope})")
            continue
        cls = classify(name, haystack)
        if cls:
            print(f"{cls:<9} {name}  (named in: {where})")
        else:
            unbacked.append(name)
            print(f"UNBACKED  {name}  (named in: {where})")

    wording_hits = []
    for p in files:
        if is_patch(p):
            continue
        try:
            lines = p.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            continue
        for line_no, line in enumerate(lines, 1):
            for bad in BANNED:
                if bad in line:
                    wording_hits.append((str(p.relative_to(ROOT)), line_no, bad, line.strip()))

    for path, line_no, bad, text in wording_hits:
        print(f'BANNED-WORDING  "{bad}"  {path}:{line_no}  ->  {text[:140]}')

    print(f"\n{len(seen)} env-var-looking names in markdown, "
          f"{len(unbacked)} unbacked, {allowed_count} allowlisted; "
          f"{len(wording_hits)} unqualified version claim(s)")
    if unbacked:
        print("\nUNBACKED means a doc names a variable no non-doc file REFERENCES (a comment or a "
              "CI service definition does not count). Either wire it, name the real config field "
              "instead, or allowlist it with a path and a reason.")
    if wording_hits:
        print(f'\nBANNED-WORDING: use the one canonical phrase instead — "{CANONICAL}". '
              "Patch files keep the old text verbatim and are exempt.")
    if unbacked or wording_hits:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
