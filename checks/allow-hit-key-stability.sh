#!/usr/bin/env bash
# checks/allow-hit-key-stability.sh — the regression test for the allow-hit KEY STABILITY defect.
#
#   usage:  allow-hit-key-stability.sh [ /path/to/bin/scan-sanitisation.sh ]
#
# The allow-marker control (checks/verify-allowed-hits.sh) keys an occurrence by rule label + path +
# line + digest of the matched line, and deliberately NOT by revision. An earlier revision of that
# control derived the label part with `substr($0, 1, length($0) - length(loc) - length(dig))`: that
# counts the two fields but not the two spaces separating them, so every key carried one character of
# the location glued to its label. On a HISTORY key that character is the first hex digit of the
# commit that landed the occurrence — so the key moved with every commit, a baseline regenerated after
# any history rewrite read as NEW+STALE at once, and the only escape available at the time was to
# narrow the lane's comparison to the tree. This script is the test that stops it recurring: one
# baseline, three history rewrites, one unchanged key set.
#
#   K0   baseline generated on the planted repo
#   K1   ...after an EMPTY commit on top
#   K2   ...after an --amend of that commit
#   K3   ...after squashing all history into a single commit
#
# For each rewrite state two things are asserted: the control PASSES against the K0 baseline (its
# normal comparison, which is what the bug broke), and a baseline generated fresh for that state is
# key-for-key identical to K0.
#
# Non-vacuity. The states ARE the detector — against the buggy expression K1, K2 and K3 all fail
# while K0 stays green. Three guards keep the run from being vacuous, so a green result means
# something:
#   * the plant must appear in HISTORY as well as in the tree (the defect was only ever visible on
#     history keys — the tree character was stable by accident);
#   * the marker must actually silence the gate (a plant the gate matches unmarked would make every
#     state below test nothing); and
#   * each state must show it rewrote a revision — HEAD must differ from the previous state's, and
#     the squash must leave exactly one commit. A no-op amend would otherwise "pass" by doing nothing.
#
# Exit: 0 all states behave · 1 a state misbehaved · 2 the fixture is vacuous or cannot run.
# Like the other probes, this file lives in the repository it tests, so every planted shape is
# assembled from parts at runtime and never appears here as a scannable literal. Writes only to a
# throwaway directory.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$HERE/.." && pwd -P)"
GATE="${1:-$ROOT/bin/scan-sanitisation.sh}"
CONTROL="$HERE/verify-allowed-hits.sh"
[ -f "$GATE" ]    || { echo "no such gate: $GATE" >&2; exit 2; }
[ -f "$CONTROL" ] || { echo "no such control: $CONTROL" >&2; exit 2; }
GATE="$(cd "$(dirname "$GATE")" && pwd -P)/$(basename "$GATE")"
# The shell under test is the shell running this probe (`${BASH:-bash}`), never whatever `bash` PATH
# resolves to — the same rule the history-state probe follows.
SH="${BASH:-bash}"

abort() { echo "ALLOW-KEY-STABILITY: ABORT — $1" >&2; exit 2; }

# Physical path: the gate's is_checkout compares git's toplevel against `pwd -P`, and on macOS mktemp
# hands back /var/... which is a symlink to /private/var.
SB="$(cd "$(mktemp -d)" && pwd -P)"
WORK="$SB/repo"
trap 'rm -rf "$SB"' EXIT

ALLOW='cofa:'"sanitise-allow"
MARK='AK''IA'"$(printf 'B2C3%.0s' {1..4})"
[ "${#MARK}" -eq 20 ] || abort "the plant is ${#MARK} chars, expected 20"
printf '%s' "$MARK" | grep -qE '^AKIA[0-9A-Z]{16}$' || abort "the plant does not match the credential class this probe needs"

mkdir -p "$WORK"
git -C "$WORK" init -q || abort "git init failed in $WORK"
git -C "$WORK" symbolic-ref HEAD refs/heads/main 2>/dev/null || true
git -C "$WORK" config user.name  stability
git -C "$WORK" config user.email "s@example"".invalid"
git -C "$WORK" config commit.gpgsign false

printf 'plain text\n' > "$WORK/README.md"
printf 'aws_access_key_id = %s   # %s\n' "$MARK" "$ALLOW" > "$WORK/config-notes.txt"
git -C "$WORK" add -A && git -C "$WORK" commit -qm "plant one approved occurrence"
printf 'second line of prose\n' >> "$WORK/README.md"
git -C "$WORK" commit -qam "second commit — gives the squash something to collapse"

# Positivity guard: the marker must silence the gate, or every state below tests nothing.
go="$SB/positive.log"
COFA_REQUIRE_HISTORY=1 "$SH" "$GATE" "$WORK" >"$go" 2>&1
prc=$?
[ "$prc" -eq 0 ] || {
  echo "ALLOW-KEY-STABILITY: ABORT — the gate exits $prc on the planted tree; the marker did not silence it," >&2
  echo "  so these states would not exercise the allow-hit key at all." >&2
  sed 's/^/    | /' "$go" | tail -8 >&2
  exit 2
}
grep -qE '^  ok +allowed:.+[0-9a-f]$' "$go" || {
  echo "ALLOW-KEY-STABILITY: ABORT — the gate printed no allowed hit with an occurrence digest for the plant." >&2
  sed 's/^/    | /' "$go" | grep -E '^  (ok|FAIL)' | head -6 >&2
  exit 2
}

# gen <id> — write a fresh baseline for the CURRENT state of $WORK, keys only.
gen() {
  rm -f "$SB/base.$1"
  # The baseline is a throwaway file in $SB, never the repository's checks/allowed-hits.expected, so
  # the CI refusal on --update (a human reviews the committed baseline) does not apply here.
  # --scope tree+history: the fixture is a throwaway repo with ordinary history, so the control must
  # compare its history keys even when the lane under test is a tree-only rebuilt lane. Without this the
  # fixture generates no history key and the whole probe is vacuous (that is how it first ran green-but-empty).
  if ! CI= "$SH" "$CONTROL" --gate "$GATE" --expected "$SB/base.$1" --scope tree+history --update "$WORK" >"$SB/gen.$1.log" 2>&1; then
    echo "ALLOW-KEY-STABILITY: FAILED — baseline generation for $1 failed:"
    sed 's/^/    | /' "$SB/gen.$1.log" | tail -10
    return 1
  fi
  grep -avE '^[[:space:]]*(#|$)' "$SB/base.$1" > "$SB/keys.$1"
}

# same_as_k0 <id> — the state must compare clean against K0 AND hash to K0's keys.
same_as_k0() {
  local out rc
  out="$(CI= "$SH" "$CONTROL" --gate "$GATE" --expected "$SB/base.K0" --scope tree+history "$WORK" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "ALLOW-KEY-STABILITY: FAILED — $1: the control rejected this history against the K0 baseline (exit $rc)"
    printf '%s\n' "$out" | sed 's/^/    | /' | head -20
    return 1
  fi
  if ! diff -u "$SB/keys.K0" "$SB/keys.$1" >"$SB/kdiff.$1" 2>&1; then
    echo "ALLOW-KEY-STABILITY: FAILED — $1: the key set moved across the rewrite (the label is carrying location)"
    sed 's/^/    | /' "$SB/kdiff.$1" | head -20
    return 1
  fi
  return 0
}

BAD=0

# ---- K0: the baseline. Must hold a tree key AND a history key -------------------------
gen K0 || { echo "ALLOW-KEY-STABILITY: ABORT — no baseline could be generated" >&2; exit 2; }
KTREE="$(grep -ac '^allowed:' "$SB/keys.K0" || true)"
KHIST="$(grep -ac '^allowed-history:' "$SB/keys.K0" || true)"
[ "${KTREE:-0}" -ge 1 ] || abort "no tree key in the baseline — the fixture did not plant an approved occurrence"
[ "${KHIST:-0}" -ge 1 ] || abort "no HISTORY key in the baseline — the defect was only visible on history keys, so this fixture tests nothing"
echo "K0: baseline — ${KTREE} tree key(s), ${KHIST} history key(s)"

PREV="$(git -C "$WORK" rev-parse HEAD)"
PREV_TREE="$(git -C "$WORK" rev-parse 'HEAD^{tree}')"

# ---- K1: an amend rewrites the commit object that landed the plant, same tree ---------
git -C "$WORK" commit -q --amend -m "second commit — amended: same tree, new revision"
[ "$(git -C "$WORK" rev-parse HEAD)" != "$PREV" ] || abort "the amend did not rewrite the commit object"
[ "$(git -C "$WORK" rev-parse 'HEAD^{tree}')" = "$PREV_TREE" ] || abort "the amend changed the tree, so it tests content churn instead of revision churn"
if gen K1 && same_as_k0 K1; then
  echo "K1: PASSED  amend — same $(wc -l < "$SB/keys.K1" | tr -d ' ') key(s)"
else
  BAD=$((BAD + 1))
fi
PREV="$(git -C "$WORK" rev-parse HEAD)"

# ---- K2: an empty commit shifts every history revision --------------------------------
git -C "$WORK" commit -q --allow-empty -m "empty commit"
[ "$(git -C "$WORK" rev-parse HEAD)" != "$PREV" ] || abort "the empty commit did not create a revision"
if gen K2 && same_as_k0 K2; then
  echo "K2: PASSED  empty commit — same $(wc -l < "$SB/keys.K2" | tr -d ' ') key(s)"
else
  BAD=$((BAD + 1))
fi

# ---- K3: squash — one commit, every revision in the baseline is now gone --------------
ROOT_COMMIT="$(git -C "$WORK" rev-list --max-parents=0 HEAD | tail -1)"
git -C "$WORK" reset -q --soft "$ROOT_COMMIT"
git -C "$WORK" commit -q --amend -m "squashed history"
[ "$(git -C "$WORK" rev-list --count HEAD | tr -d ' ')" -eq 1 ] || abort "the squash left $(git -C "$WORK" rev-list --count HEAD) commits, expected 1"
if gen K3 && same_as_k0 K3; then
  echo "K3: PASSED  squash — same $(wc -l < "$SB/keys.K3" | tr -d ' ') key(s)"
else
  BAD=$((BAD + 1))
fi

if [ "$BAD" -eq 0 ]; then
  echo "ALLOW-KEY-STABILITY: PASSED (4 of 4 states hold one key set — a marker's key survives an empty commit, an amend and a squash)"
  exit 0
fi
echo "ALLOW-KEY-STABILITY: FAILED ($BAD of 3 rewrite states misbehaved — the allow-hit key is not revision-independent)"
exit 1
