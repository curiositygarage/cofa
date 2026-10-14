#!/usr/bin/env bash
# checks/verify-allowed-hits.sh — the allow-marker control.
#
# `cofa:sanitise-allow` silences a finding on its own line. The gate PRINTS every allowed hit (tree and
# history), but printing is not control: a marker appended to a real secret still exits 0. This script is the
# control. It runs the gate, extracts every allowed hit as a stable key (rule label + path + line + digest of the
# matched line; NO commit hash, NO absolute root), and requires the set to equal the reviewed baseline
# checks/allowed-hits.expected. The digest is what makes the key occurrence-specific — without it a second marked
# hit in an already-approved path produced no new key and both controls stayed green (COFA-SAN-001, 2026-10-14).
#
#   checks/verify-allowed-hits.sh                 compare; exit 0 equal, 1 differs, 2 cannot run
#   checks/verify-allowed-hits.sh --update        rewrite the baseline (refused when $CI is set); REVIEW the diff, then commit
#   options: --gate PATH   --expected PATH   --tree-only   [DIR to scan, default: repository root]
#
# SCOPE — which occurrences this control compares. By default the key set is tree AND history. A lane whose
# history is REBUILT on every publish (a squashed snapshot: each revision is regenerated from the same tree)
# cannot hold a stable history baseline — a history occurrence's identity depends on the commit that landed
# it, including the baseline commit itself, so the comparison churns by construction and never converges.
# Such a lane declares its scope in checks/allow-control.scope — a committed, reviewable file whose value is
# `tree`: compare tree occurrences only. Absent that file the scope stays tree+history, which is the correct
# default for a development repo. The scope is PRINTED on every run and recorded in the baseline: a scope that
# changes silently is a defect, not a configuration. Narrowing the *comparison* does not narrow the *scan* —
# the gate still scans the full history for leaks, and a marker silencing a private-overlay match still fails.
#
# Two rules, because they answer different questions:
#   1. BASELINE: an allowed hit not in the baseline is new (a marker someone added: a human must approve it);
#      a baseline entry that no longer occurs is stale (the file must stay the truth). Either fails.
#   2. OVERLAY: an allowed hit whose label comes from the private denylist is NEVER legitimate. The marker exists
#      for shipped pattern classes (a pin, a pattern's own definition). On an operator string it is laundering.
#      This fails regardless of the baseline, and it is environment-independent (CI has no overlay; locally it does).
#
# Output is labels and paths only. Written for bash 3.2 (no mapfile, no associative arrays).
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"; ROOT="$(cd "$HERE/.." && pwd -P)"
GATE="$ROOT/bin/scan-sanitisation.sh"; EXPECTED="$ROOT/checks/allowed-hits.expected"; TARGET="$ROOT"; UPDATE=0
TREE_ONLY=0; SCOPE_FILE="$ROOT/checks/allow-control.scope"
while [ $# -gt 0 ]; do
  case "$1" in
    --update)    UPDATE=1; shift ;;
    --tree-only) TREE_ONLY=1; shift ;;
    --gate)      GATE="$2"; shift 2 ;;
    --expected)  EXPECTED="$2"; shift 2 ;;
    -h|--help)   sed -n '2,32p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*)          echo "usage: $0 [--update] [--tree-only] [--gate PATH] [--expected PATH] [DIR]" >&2; exit 2 ;;
    *)           TARGET="$1"; shift ;;
  esac
done

# Lane scope: the explicit flag wins, else the committed marker, else the development default (tree + history).
# Resolved BEFORE the gate runs, and printed on every run, so a scope change is always visible in the output.
SCOPE="tree+history"
if [ "$TREE_ONLY" -eq 1 ]; then
  SCOPE="tree-only (--tree-only)"
elif [ -f "$SCOPE_FILE" ] && grep -qE '^[[:space:]]*tree(-only)?[[:space:]]*(#.*)?$' "$SCOPE_FILE"; then
  SCOPE="tree-only (checks/allow-control.scope)"
fi

[ -x "$GATE" ] || { echo "verify-allowed-hits: gate not found or not executable: $GATE" >&2; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
COFA_REQUIRE_HISTORY="${COFA_REQUIRE_HISTORY:-1}" "$GATE" "$TARGET" > "$TMP/gate.out" 2>&1; grc=$?
[ "$grc" -le 1 ] || { echo "verify-allowed-hits: the gate could not run (exit $grc); an uncontrolled gate is not a control" >&2; exit 2; }

# Key = "<label> <path>:<line> <digest>". The digest is the gate's 12-char hash of the MATCHED LINE: it
# carries occurrence identity without carrying the value, and it changes when the line changes, so an
# approved occurrence cannot be swapped and a second marked hit in an already-approved path is no longer
# invisible. (Before this, the key was label+path only and `sort -u` collapsed occurrences: a marked
# secret planted in an approved path left both this control and the gate green — external review
# 2026-10-14, finding COFA-SAN-001, reproduced on this tree.) The revision is deliberately NOT part of
# the key: the same approved line lives in many commits, and keying on the commit would make the
# baseline churn on every commit instead of answering "is this occurrence approved?".
# The location is second-to-last and the label is everything before it, so a label containing spaces
# (e.g. a PRIVATE KEY pattern prefix) cannot split the record.
grep -aE '^  ok +allowed(-history)?:' "$TMP/gate.out" | sed -E 's/^  ok +//' | awk '
  { dig = $NF; loc = $(NF-1)
    if (loc !~ /:/ || dig !~ /^[0-9a-f]+$/) { print "MALFORMED:" $0; next }
    pre = substr($0, 1, length($0) - length(loc) - length(dig)); sub(/[ \t]+$/, "", pre); gsub(/ /, "_", pre)
    n = split(loc, a, ":")
    hist = (pre ~ /^allowed-history:/)
    path = hist ? a[2] : a[1]
    line = hist ? a[3] : a[2]
    print pre " " path ":" line " " dig }' | sort -u > "$TMP/now.raw"
grep -av '^MALFORMED' "$TMP/now.raw" > "$TMP/now" 2>/dev/null || true
if [ -n "$(grep -a '^MALFORMED' "$TMP/now.raw" 2>/dev/null || true)" ]; then
  echo "verify-allowed-hits: FAILED — the gate printed an allowed hit with no occurrence identity (digest)." >&2
  echo "  Occurrence identity is what stops a second marked hit from riding an approved key; without it this" >&2
  echo "  control is blind by construction. Upgrade checks/pre-push + bin/scan-sanitisation.sh together." >&2
  grep -a '^MALFORMED' "$TMP/now.raw" 2>/dev/null | sed 's/^/    /' | head -5 >&2
  exit 2
fi

# Rule 2 first: marker on a private-overlay match is never legitimate.
overlay="$(grep -aE '^allowed(-history)?:denylist:' "$TMP/now" || true)"
if [ -n "$overlay" ]; then
  echo "verify-allowed-hits: FAILED — a marker is silencing a PRIVATE OVERLAY match (never legitimate):"
  printf '%s\n' "$overlay" | sed 's/^/  /'
  exit 1
fi

if [ "${SCOPE%% *}" = "tree-only" ]; then
  keys_before="$(wc -l < "$TMP/now" | tr -d ' ')"
  grep -av '^allowed-history:' "$TMP/now" > "$TMP/now.tree" 2>/dev/null || true
  mv "$TMP/now.tree" "$TMP/now"
  keys_after="$(wc -l < "$TMP/now" | tr -d ' ')"
  echo "verify-allowed-hits: scope $SCOPE — comparing $keys_after key(s); $((keys_before - keys_after)) history occurrence(s) not compared (the gate still scans them for leaks)"
else
  echo "verify-allowed-hits: scope $SCOPE"
fi

if [ "$UPDATE" -eq 1 ]; then
  [ -z "${CI:-}" ] || { echo "verify-allowed-hits: --update is refused in CI; the baseline is reviewed by a human" >&2; exit 2; }
  { echo "# Reviewed baseline of allow-marker hits (rule label + path + line + digest of the matched line)."
    echo "# Generated by checks/verify-allowed-hits.sh --update. A line here means: a human looked at this"
    echo "# occurrence and agreed it is legitimate. Do not edit by hand to make a run pass."
    echo "# SCAN SCOPE: $SCOPE — these are the occurrences this control compares (see the SCOPE note at the top)."
    cat "$TMP/now"; } > "$EXPECTED"
  echo "verify-allowed-hits: baseline written: $(wc -l < "$TMP/now" | tr -d ' ') entr(ies) -> $EXPECTED"; echo "REVIEW every line (git diff) before committing."; exit 0
fi

[ -f "$EXPECTED" ] || { echo "verify-allowed-hits: no baseline at $EXPECTED (run --update, review, commit)" >&2; exit 2; }
grep -avE '^[[:space:]]*(#|$)' "$EXPECTED" | sort -u > "$TMP/want"
new="$(comm -13 "$TMP/want" "$TMP/now")"; stale="$(comm -23 "$TMP/want" "$TMP/now")"
if [ -z "$new" ] && [ -z "$stale" ]; then
  echo "verify-allowed-hits: PASSED — $(wc -l < "$TMP/now" | tr -d ' ') allowed hit key(s) [$SCOPE], all in the reviewed baseline, none on a private-overlay match"; exit 0
fi
echo "verify-allowed-hits: FAILED — the allowed hits differ from the reviewed baseline [$SCOPE]"
[ -z "$new" ]   || { echo "  NEW (a marker nobody approved):"; printf '%s\n' "$new" | sed 's/^/    + /'; }
[ -z "$stale" ] || { echo "  STALE (in the baseline, no longer occurring — update the baseline):"; printf '%s\n' "$stale" | sed 's/^/    - /'; }
exit 1

