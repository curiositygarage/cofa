#!/usr/bin/env bash
# checks/verify-all.sh — THE entry point.
#
# One command a public cloner can run to reproduce the green run, and the exact command CI runs.
#
#   ./checks/verify-all.sh                 full run; a component that cannot be verified is REPORTED
#   ./checks/verify-all.sh --require-all   ...and makes the run fail (CI uses this)
#
# Order matters twice over. (1) Each component proves its own runtime behaviour. (2) The tree +
# history scan runs LAST: an earlier step can write a file, and a scan that ran before it would
# never see it (external review, round 5 — the probe's .pyc was caught only by luck of ordering).
#
# Exit codes
#   0  every check ran and passed (a component that could not be verified is printed, not hidden)
#   1  a check FAILED
#   2  a component could NOT be verified (its prerequisite is absent) and --require-all was given
#   3  usage
#
# The distinction between exit 1 and exit 2 is the point: the four component verifiers exit 2 when
# they cannot reach their prerequisite, and "could not verify" must never read as "verified".
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 3

REQUIRE_ALL=false
case "${1:-}" in
  --require-all) REQUIRE_ALL=true ;;
  "")            ;;
  *)             echo "usage: $0 [--require-all]" >&2; exit 3 ;;
esac

# Both throwaway directories come down through ONE function: in bash a second `trap ... EXIT`
# REPLACES the first, so a later `trap 'rm -rf "$PROV"' EXIT` would silently leak $LOGS instead
# (external review, round 5g).
LOGS="$(mktemp -d)"
PROV=""
cleanup() { [ -n "$PROV" ] && rm -rf "$PROV"; rm -rf "$LOGS"; }
trap cleanup EXIT
fails=0; skips=0; passes=0

step() {   # step <label> <cmd...>
  local label="$1"; shift
  local log="$LOGS/$(printf '%s' "$label" | tr -c 'A-Za-z0-9' _).log"
  local rc=0
  printf '\n=== %s\n' "$label"
  "$@" >"$log" 2>&1 || rc=$?
  case "$rc" in
    0) printf '  PASS          %s\n' "$label"
       tail -3 "$log" | sed 's/^/                /'
       passes=$((passes + 1)) ;;
    2) printf '  NOT VERIFIED  %s — prerequisite missing (exit 2); this is NOT a pass\n' "$label"
       tail -6 "$log" | sed 's/^/                /'
       skips=$((skips + 1)) ;;
    *) printf '  FAIL          %s (exit %s)\n' "$label" "$rc"
       tail -25 "$log" | sed 's/^/                /'
       fails=$((fails + 1)) ;;
  esac
}

# gate_step — for the GATE, every non-zero exit is a FAILURE.
# The gate's own contract is 0 = clean, 1 = findings, 2 = usage/internal error. Folding its exit 2
# into the same "NOT VERIFIED" bucket as a missing component prerequisite meant a BROKEN gate
# (one that cannot run at all — e.g. a bash-4 builtin under an older shell) still produced an
# overall PASS: "PASSED with 1 NOT VERIFIED", exit 0. Found by the external review with a stand-in
# gate that exits 2. A verification tool that cannot run must never read as "not my problem".
gate_step() {   # gate_step <label> <cmd...>
  local label="$1"; shift
  local log="$LOGS/$(printf '%s' "$label" | tr -c 'A-Za-z0-9' _).log"
  local rc=0
  printf '\n=== %s\n' "$label"
  "$@" >"$log" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '  PASS          %s\n' "$label"
    tail -3 "$log" | sed 's/^/                /'
    passes=$((passes + 1))
  else
    printf '  FAIL          %s (exit %s — a gate that cannot run is not a gate)\n' "$label" "$rc"
    tail -25 "$log" | sed 's/^/                /'
    fails=$((fails + 1))
  fi
}

# Strict history: verify-all.sh IS the release check, so a tree whose history cannot be scanned is a
# FAILURE here, never a note. The gate's own selftest clears the variable internally: it scans
# throwaway trees that are not checkouts by design (external review, round 5).
export COFA_REQUIRE_HISTORY=1

# Bytecode-free: this run scans the tree, and a stray __pycache__/*.pyc inside it is a REAL finding
# ("binary is never pattern-scanned"), so the release check must not create one while it runs.
export PYTHONDONTWRITEBYTECODE=1

# The peer-text probe is the regression test for the A2A client's OUTPUT integrity: the exit code can
# be right while the printed line is the peer's. Non-vacuous: 5/20 fail against the revision before
# the _q fix (bfdb6bd); 20/20 pass on the current tree.
gate_step "a2a peer-text probe (20 forge shapes)" python3 checks/a2a-client-peer-text.py

# Doc-vs-code, rule 1: every ENV_VAR-looking name in markdown must be READ by a non-doc file.
# The rule exists because `A2A_PEER_ENDPOINTS` shipped in two KEYS-REQUIRED tables while nothing in
# the tree read that name — a reader would have set a variable that does not exist (review, r8).
# Round 9 tightened "appears" to a read pattern: a mention in a comment or a CI service
# definition backs nothing, so the rule cannot be satisfied by text that reads no name.
# Rule 2 in the same step: the client's version claim has ONE canonical phrase
# (`A2A-style JSON-RPC client (v1.0 SendMessage dialect)`); unqualified shapes fail.
gate_step "doc claims (env names must be read; one canonical version phrase)" \
          python3 checks/verify-doc-claims.py
# Doc-vs-code, rule 3: a KEYS-REQUIRED announcement hands the reader an exact line. If no shell or
# Python file prints it, the doc promises a message that does not exist — `REQUIREDCHECK my_agent_id`
# survived a round while the a2a verifier prints `REQUIREDCHECK a2a-mesh-config` (review, r9).
gate_step "doc claims (REQUIREDCHECK strings must be printed by code)" \
          python3 checks/verify-doc-strings.py

gate_step "gate selftest (the gate must be able to fail)" bin/scan-sanitisation.sh --selftest
gate_step "portability (bash 3.2 — what macOS ships)"     checks/verify-portability.sh
gate_step "portability selftest (it must be able to fail)" checks/verify-portability.sh --selftest
# The plant matrix is the regression test for the gate's own hole classes: it builds a throwaway
# repo per leak shape and requires the gate to exit 1. A gate_step, not a step — a matrix that
# cannot run is a failure, never a "not verified". v3 adds the home-path shapes (Q1-Q5: macOS
# /Users, Windows C:\Users, capitalised and digit-first usernames, /root) over v2's 33.
gate_step "plant matrix (UTF-8 locale; the matrix prints its own count)" bash checks/gate-plant-matrix-v4.sh bin/scan-sanitisation.sh
# The redaction probe is the regression test for the OTHER half of the gate's contract: a finding
# must not print the value it found. It plants one leak per shape and requires the gate to fail
# WITHOUT printing the planted marker. Non-vacuous: it fails 14/14 against the revision that
# printed values (that revision is what this step replaced). v2 adds multi-line commit/tag bodies,
# the peer key, and a denylist-REGEX file name (R15-R19). R20 (round 11) is the one-file tree, the
# shape where `grep` has no file-name column to print and the matched text escapes unfiltered.
gate_step "redaction probe (20 shapes — a failure must not print the value)" \
          bash checks/gate-redaction-probe-v2.sh bin/scan-sanitisation.sh
# ---------------------------------------------------------- provisioning (external review, r5g)
# A CI runner — and any machine that is not a deployment — has no ~/.config/cofa. Two wrong shapes
# were available: let the verifiers read the operator's REAL config (which is what a local run did,
# so it exercised the LTM verifier against whichever database the operator happens to point at), or
# let them report NOT VERIFIED for want of a file. Both are answered by building a throwaway
# deployment here, so the four components are genuinely exercised and a laptop and CI run the same
# path. Samples are copied where they exist — a broken sample then FAILS the run instead of passing
# quietly — and a2a-mesh plus long-term-memory are written explicitly because they need real-shaped
# values. Nothing in here reads or writes $HOME.
PROV="$(mktemp -d)"
mkdir -p "$PROV/a2a-mesh" "$PROV/continuity" "$PROV/policy-cel/rules" "$PROV/long-term-memory"

# continuity + policy-cel: the shipped samples, with the sample's literal `~/.config/cofa/...` paths
# and its relative rules_dir rewritten to this directory. The continuity client DOES expand `~`, so
# an unrewritten copy would put checkpoints in the operator's real home — which is why the guard for
# this asserts on all of $HOME, not merely on these two files. Write-then-move: never `sed -i`,
# which is GNU-only and this must run on macOS.
for comp in continuity policy-cel; do
  sed -e "s#~/.config/cofa#$PROV#g" -e "s#\"\./rules/\"#\"$PROV/policy-cel/rules/\"#" \
      "$comp/config.sample.yaml" > "$PROV/$comp/config.yaml.new" || exit 3
  mv "$PROV/$comp/config.yaml.new" "$PROV/$comp/config.yaml"
done
cp policy-cel/rules/*.cel "$PROV/policy-cel/rules/" || exit 3

# a2a-mesh: the sample ships <placeholders>; the verifier starts its own receivers, so the peer only
# has to look real — a real-shaped id and a loopback endpoint.
cat > "$PROV/a2a-mesh/config.yaml" <<'YAML'
my_agent_id: "cofa_verify"
timeout_ms: 60000
retry_attempts: 2
peers:
  cofa_verify_peer:
    endpoint: "http://127.0.0.1:45999/a2a"
    id: "cofa_verify_peer_id"
YAML

# long-term-memory: built from the test database's credentials, NEVER from the operator's config.
# When they are absent the config is deliberately not written, so the verifier reports the
# prerequisite absent rather than silently checking somebody's real database.
LTM_PROVISIONED=no
if [ -n "${COFA_TEST_PG_HOST:-}" ] && [ -n "${COFA_TEST_PG_DATABASE:-}" ]; then
  {
    printf 'pg:\n'
    printf '  host: "%s"\n'     "$COFA_TEST_PG_HOST"
    printf '  port: %s\n'       "${COFA_TEST_PG_PORT:-5432}"
    printf '  database: "%s"\n' "$COFA_TEST_PG_DATABASE"
    printf '  username: "%s"\n' "${COFA_TEST_PG_USER:-postgres}"
    printf '  password: "%s"\n' "${COFA_TEST_PG_PASSWORD:-}"
    printf 'namespace: "cofa_verify"\n'
  } > "$PROV/long-term-memory/config.yaml"
  LTM_PROVISIONED=yes
fi
export COFA_CONFIG_DIR="$PROV"
if [ "$LTM_PROVISIONED" = yes ]; then
  printf '\n=== provisioning: throwaway deployment at %s (long-term-memory from COFA_TEST_PG_*)\n' "$PROV"
else
  printf '\n=== provisioning: throwaway deployment at %s (long-term-memory NOT provisioned — no\n' "$PROV"
  printf '    COFA_TEST_PG_* in the environment, so the harness reports that component NOT\n'
  printf '    VERIFIED instead of reading the home deployment — and --require-all then fails\n'
  printf '    on it, which is the correct reading: not verified is not verified.)\n'
fi

step "component: a2a-mesh"                           a2a-mesh/checks/verify.sh
step "component: policy-cel"                         policy-cel/checks/verify.sh
step "component: continuity"                         continuity/checks/verify.sh
# The harness — not the component — turns "no test credentials" into NOT VERIFIED, with a message
# that says what to set. The component's own exit codes stay untouched: a missing *config* is its
# failure (exit 1), and exit 2 is reserved for a prerequisite it cannot reach (a missing driver).
if [ "$LTM_PROVISIONED" = yes ]; then
  step "component: long-term-memory"                 long-term-memory/checks/verify.sh
else
  printf '  NOT VERIFIED  component: long-term-memory — no COFA_TEST_PG_* in the environment\n'
  printf '                set COFA_TEST_PG_HOST/PORT/DATABASE/USER/PASSWORD to a scratch database\n'
  skips=$((skips + 1))
fi

# THE TREE + HISTORY SCAN RUNS LAST. Every step above can write a file — the component verifiers
# certainly can — and a scan that ran before them would never see what they left. Running it last
# means anything a step leaves behind is inside the artifact the gate judges. The
# PYTHONDONTWRITEBYTECODE=1 export above keeps this run from creating a .pyc of its own while it
# does; a stray __pycache__ in the tree is a real finding ("binary is never pattern-scanned").
# The history-state probe is the regression test for the gate's HISTORY-STATE handling itself: a
# shallow clone, a linked worktree and a bare mirror must each FAIL the gate rather than read green.
# Nothing else here exercises those three behaviours, so without this step an edit that reintroduces
# `[ -d "$dir/.git" ]` or drops the shallow check still produces a full green run — those behaviours
# are unguarded, not unverified (external review, round 5). `bash`, not `sh`: the probe aborts on a
# too-short plant instead of passing. It sets COFA_REQUIRE_HISTORY per case itself and writes only
# to temp directories, so it cannot disturb the scan that runs last.
gate_step "history-state probe (shallow / worktree / bare must not read green)" \
          bash checks/gate-history-state-probe.sh bin/scan-sanitisation.sh

# An `--amend` leaves the ORIGINAL commit in the object store, and the gate's identity rule reads
# `git log --all`, so the gate cannot see it — that is the incident this whole review started from
# (a pre-amend commit carrying a private identity shipping in every zip). Ids are printed, never
# content, so a failing run is safe in a public log. Runs before the gate scan, and writes nothing.
gate_step "unreachable objects (fsck --unreachable --no-reflogs must be empty)" \
          bash checks/verify-unreachable.sh
# The allow-marker control (round 19). An allow-marker is a comment the gate treats as "reviewed,
# ignore this hit"; until now NOTHING failed when one was added, so a marker could launder a secret.
# The control re-runs the gate and requires every COMPARED allowed hit to match the reviewed baseline
# checks/allowed-hits.expected — tree + history by default, tree only on a lane that declares
# checks/allow-control.scope (a rebuilt-history lane, where a history baseline cannot be stable; see the
# SCOPE note in the control's header). It refuses outright any marker silencing a private-overlay match,
# in either scope. Its exit 2 (no baseline, or the gate could not run) is a FAILURE here:
# a control that cannot run is not a control. It writes nothing, so it may sit before the scan.
gate_step "allow-marker control (every allowed hit must be in the reviewed baseline)" \
          bash checks/verify-allowed-hits.sh

gate_step "gate scan (tree + history) — LAST, after every step that can write" bin/scan-sanitisation.sh

printf '\n=== summary: %d passed · %d failed · %d not verified\n' "$passes" "$fails" "$skips"

if [ "$fails" -ne 0 ]; then
  printf 'STATUS: FAILED — %d check(s) failed. Nothing here is publishable until this is 0.\n' "$fails"
  exit 1
fi
if [ "$skips" -ne 0 ]; then
  if $REQUIRE_ALL; then
    printf 'STATUS: FAILED — %d component(s) NOT VERIFIED and --require-all was given.\n' "$skips"
    exit 2
  fi
  printf 'STATUS: PASSED with %d component(s) NOT VERIFIED — not a full verification.\n' "$skips"
  printf '        Install the missing component (SETUP-GUIDE.md) and re-run, or pass --require-all to make this fatal.\n'
  exit 0
fi
printf 'STATUS: PASSED — the gate and all four components verified on this machine.\n'
