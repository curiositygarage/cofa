#!/usr/bin/env bash
# Long-Term Memory — verification.
#
# Contract: exit 0 ONLY when memory actually persists on this machine.
#   exit 0 = deployed config resolved, database reachable, a fact written and read back,
#            a foreign namespace confirmed empty
#   exit 1 = a check failed (each failure names what to fix)
#   exit 2 = usage / missing prerequisite
#
# Non-vacuity: phase 0 re-runs this script with an EMPTY config dir and requires FAILURE.
# Nothing here is satisfied by tooling merely being installed — the round-trip is the proof.
#
# Deployed config: ${COFA_CONFIG_DIR:-$HOME/.config/cofa}/long-term-memory/config.yaml
set -uo pipefail

# A checker must not perturb the artifact it inspects: importing a shipped module writes
# __pycache__/*.pyc into the component tree, and the no-mutation phase below would then
# (correctly) flag the checker's own side effect as an edit. Disable bytecode writing here
# rather than documenting an env var the operator has to remember.
export PYTHONDONTWRITEBYTECODE=1

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPONENT_DIR="$(cd "$SELF_DIR/.." && pwd)"
CLIENT="$COMPONENT_DIR/lib/memory.py"
CONFIG_DIR="${COFA_CONFIG_DIR:-$HOME/.config/cofa}"
CONFIG="$CONFIG_DIR/long-term-memory/config.yaml"
TMP="$(mktemp -d)"
RUN_ID="$$-$(date +%s)"
NS_MAIN="cofa_verify_${RUN_ID}"
NS_FOREIGN="cofa_verify_${RUN_ID}_other"
trap 'rm -rf "$TMP"' EXIT

echo "=== Long-Term Memory Verify ==="
echo "config: $CONFIG"

# ------------------------------------------------------------------ prerequisites
if ! command -v python3 >/dev/null 2>&1; then
  echo "REQUIREDCHECK python3: long-term-memory's client and verifier are Python 3.9+ scripts."
  exit 2
fi
if [ ! -f "$CLIENT" ]; then
  fail "client missing: $CLIENT"
  echo "Results: $PASS passed  $FAIL failed"
  exit 1
fi

# ------------------------------------------------------------------ phase 0: can it fail?
if [ "${COFA_VERIFY_SELFCHECK:-0}" != "1" ]; then
  EMPTY="$(mktemp -d)"
  COFA_CONFIG_DIR="$EMPTY" COFA_VERIFY_SELFCHECK=1 bash "$0" >"$TMP/selfcheck.log" 2>&1
  rc=$?
  rm -rf "$EMPTY"
  if [ "$rc" -ne 0 ]; then
    pass "self-check: verifier FAILS when the component is not deployed (exit $rc)"
  else
    fail "self-check: verifier PASSED with an empty config dir — it cannot fail, so it proves nothing"
  fi
fi

# ------------------------------------------------------------------ phase 1: backend
if python3 -c "import psycopg2" 2>/dev/null; then
  pass "backend: psycopg2 available"
elif command -v psql >/dev/null 2>&1; then
  pass "backend: no psycopg2, falling back to the psql client"
else
  fail "no backend: install psycopg2 (pip install psycopg2-binary) or the postgresql client"
  echo "REQUIREDCHECK psycopg2-or-psql: long-term-memory needs one of them to reach PostgreSQL."
fi

# ------------------------------------------------------------------ phase 2: deployed config
CFG_OK=0
if [ ! -f "$CONFIG" ]; then
  fail "no deployed config at $CONFIG — the component is not installed"
  echo "REQUIREDCHECK cofa-memory-config: copy config.sample.yaml there and set pg.host/pg.database/namespace."
else
  BAD="$(python3 - "$CONFIG" "$CLIENT" <<'PY'
import importlib.util, sys

spec = importlib.util.spec_from_file_location("memory", sys.argv[2])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
try:
    cfg = mod.load_config(sys.argv[1])
    params = mod.pg_params(cfg)
except Exception as exc:
    print(str(exc)); raise SystemExit(0)
problems = []
ns = str(cfg.get("namespace") or "")
if not ns or "<" in ns:
    problems.append(f"namespace is unset or a placeholder ({ns!r})")
if not params.get("user"):
    problems.append("pg.username is empty")
print("; ".join(problems))
PY
)"
  if [ -z "$BAD" ]; then
    pass "deployed config is real (pg.host, pg.database, namespace all set)"
    CFG_OK=1
  else
    fail "deployed config is unusable: $BAD"
  fi
fi

# ------------------------------------------------------------------ no-mutation guard
BEFORE="$(cd "$COMPONENT_DIR" && find . -type f -not -path '*/__pycache__/*' -not -name '*.pyc' | sort | sha256sum | cut -d' ' -f1)"

if [ "$CFG_OK" -eq 1 ]; then
  # ---------------------------------------------------------------- phase 3: round-trip
  if python3 "$CLIENT" --config "$CONFIG" --namespace "$NS_MAIN" write "cofa verify round-trip $NS_MAIN" >"$TMP/write.out" 2>&1; then
    pass "write accepted: $(cat "$TMP/write.out")"
  else
    rc=$?
    fail "write failed (exit $rc): $(cat "$TMP/write.out")"
  fi

  if python3 "$CLIENT" --config "$CONFIG" --namespace "$NS_MAIN" read "round-trip" >"$TMP/read.out" 2>"$TMP/read.err"; then
    if grep -q "$NS_MAIN" "$TMP/read.out"; then
      pass "read-back returns the exact fact written — memory persists"
    else
      fail "read-back did not return the written fact: $(cat "$TMP/read.out")"
    fi
  else
    fail "read failed (exit $?): $(cat "$TMP/read.err" | tail -1)"
  fi

  # ---------------------------------------------------------------- phase 4: isolation
  FOREIGN_COUNT="$(python3 "$CLIENT" --config "$CONFIG" --namespace "$NS_FOREIGN" count 2>"$TMP/count.err" || echo ERR)"
  if [ "$FOREIGN_COUNT" = "0" ]; then
    pass "namespace isolation: a different namespace sees 0 of $NS_MAIN's facts"
  else
    fail "namespace isolation broken: foreign namespace count=$FOREIGN_COUNT ($(tail -1 "$TMP/count.err" 2>/dev/null))"
  fi

  # ---------------------------------------------------------------- phase 3b: query is data, not a pattern
  # A search string containing `_` or `%` must match itself, not act as a LIKE wildcard.
  python3 "$CLIENT" --config "$CONFIG" --namespace "$NS_MAIN" write "cofa wildcard probe a_b" >/dev/null 2>&1
  python3 "$CLIENT" --config "$CONFIG" --namespace "$NS_MAIN" write "cofa wildcard decoy axb" >/dev/null 2>&1
  if python3 "$CLIENT" --config "$CONFIG" --namespace "$NS_MAIN" read "a_b" >"$TMP/wild.out" 2>"$TMP/wild.err"; then
    if grep -q 'a_b' "$TMP/wild.out" && ! grep -q 'axb' "$TMP/wild.out"; then
      pass "read treats the query as a literal: 'a_b' matched itself and not the 'axb' decoy"
    else
      fail "'a_b' behaved as a wildcard — decoy returned: $(tr '\n' ' ' < "$TMP/wild.out")"
    fi
  else
    fail "wildcard probe read failed (exit $?): $(tail -1 "$TMP/wild.err")"
  fi

  # ---------------------------------------------------------------- cleanup
  python3 "$CLIENT" --config "$CONFIG" drop-namespace "$NS_MAIN" >/dev/null 2>&1 \
    && pass "cleanup: verification facts removed from namespace $NS_MAIN" \
    || fail "cleanup failed — verification rows left in $NS_MAIN"
else
  fail "round-trip, isolation and cleanup checks SKIPPED (no usable deployed config)"
fi

# ------------------------------------------------------------------ phase 5: negative test
# An unreachable database must fail loudly, not degrade to a warning.
sed -E 's/^([[:space:]]*port:[[:space:]]*).*/\159999/' "$CONFIG" > "$TMP/unreachable.yaml" 2>/dev/null
if [ -f "$TMP/unreachable.yaml" ] && grep -q '59999' "$TMP/unreachable.yaml"; then
  python3 "$CLIENT" --config "$TMP/unreachable.yaml" --namespace "$NS_MAIN" init >"$TMP/unreach.out" 2>&1
  rc=$?
  if [ "$rc" -eq 3 ]; then
    pass "negative test: unreachable database → exit 3 ($(tail -1 "$TMP/unreach.out"))"
  else
    fail "negative test: expected exit 3 for an unreachable database, got exit $rc: $(tail -1 "$TMP/unreach.out")"
  fi
else
  skip_note="negative test skipped (could not build an unreachable-database fixture)"
  fail "$skip_note"
fi

# ------------------------------------------------------------------ phase 6: no mutation
AFTER="$(cd "$COMPONENT_DIR" && find . -type f -not -path '*/__pycache__/*' -not -name '*.pyc' | sort | sha256sum | cut -d' ' -f1)"
if [ "$BEFORE" = "$AFTER" ]; then
  pass "verification did not modify the component tree (no files written into the checkout)"
else
  fail "verification mutated the component tree — the checker must work in a temp dir"
fi

# ------------------------------------------------------------------ summary
echo ""
echo "Results: $PASS passed  $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "STATUS: FAILED — long-term-memory is NOT operational on this machine."
  exit 1
fi
echo "STATUS: PASSED — facts persist, namespaces are isolated, failures are loud."
exit 0
