#!/usr/bin/env bash
# checks/gate-history-state-probe.sh — is the gate's HISTORY-STATE handling regression-tested?
#
#   usage:  gate-history-state-probe.sh /path/to/bin/scan-sanitisation.sh
#
# Round 5 gave the gate four behaviours that nothing else in the release check exercises:
#   * a SHALLOW clone is a finding (history is truncated — a leak outside the window is invisible)
#   * a tree that is NOT a checkout is a finding under COFA_REQUIRE_HISTORY=1 (a bare mirror has
#     no working tree to scan)
#   * `is_checkout` replaced the bare `[ -d "$dir/.git" ]` test, which was FALSE for a LINKED
#     WORKTREE (its .git is a FILE) — so the history scan was skipped, an "ok" line was printed,
#     and the whole run passed.
#   * a PARTIAL (blobless) clone whose remote is unreachable holds objects the scan cannot read;
#     `git grep` skips them, the gate's 2>/dev/null hides it, and an incomplete history reads
#     "clean" — so the count of unreadable objects is itself a finding.
# Without this probe an edit that reintroduces `[ -d "$dir/.git" ]` or drops the shallow check
# still produces a green run: those behaviours would be unguarded, not unverified.
#
# Five states, one plant. A throwaway repo carries a credential in an OLDER commit and a spotless
# HEAD, so only the history scan can report it:
#
#   H-FULL      normal clone        -> credential found in history  (positivity control: the plant works)
#   H-SHALLOW   clone --depth 1     -> shallow-history              (the window cannot see the plant)
#   H-WORKTREE  git worktree add    -> credential found in history  (NOT "history not scanned")
#   H-BARE      clone --mirror      -> history-not-scanned under COFA_REQUIRE_HISTORY=1
#   H-PARTIAL   blobless, remote gone -> history-incomplete          (objects missing, so unscanned)
#
# Exit 0 only if all five behaved. Non-vacuous: against the gate before the round-5 history patch,
# H-SHALLOW, H-WORKTREE, H-BARE and H-PARTIAL all read green and this probe fails 4 of 5.
#
# The shell that runs the GATE is the shell running this probe (`${BASH:-bash}`), never whatever
# `bash` PATH resolves to: on a macOS runner a Homebrew bash 5 earlier in PATH would otherwise
# exercise the states under a shell the job never claimed to test — the same vacuity the
# bash-major assertion exists to prevent.
#
# The H-PARTIAL fixture proves it is partial before asserting anything (a filtered clone silently
# degrades to a full one when the source lacks uploadpack.allowFilter; that makes the state
# vacuous, so it aborts instead).
#
# Like the plant matrix, this file lives in the repository it tests, so every key shape below is
# assembled from parts at runtime and never appears as a scannable literal.
set -u

GATE="${1:?usage: $0 /path/to/bin/scan-sanitisation.sh}"
[ -f "$GATE" ] || { echo "no such gate: $GATE" >&2; exit 3; }
GATE="$(cd "$(dirname "$GATE")" && pwd -P)/$(basename "$GATE")"

# Physical path on purpose: on macOS mktemp hands back /var/... which is a symlink to /private/var,
# and the gate's is_checkout compares git's toplevel against `pwd -P`. A logical temp root would
# make the WORKTREE case read as "not a checkout" for a reason that has nothing to do with the gate.
SB="$(cd "$(mktemp -d)" && pwd -P)"
SRC="$SB/src"
trap 'rm -rf "$SB"' EXIT

# Credential class: AKIA + exactly 16 chars of [0-9A-Z]. Built from parts (see header).
MARK="AK""IA$(printf 'A1B2%.0s' {1..4})"
[ "${#MARK}" -eq 20 ] || { echo "ABORT: test secret is ${#MARK} chars, expected 20" >&2; exit 2; }
printf '%s' "$MARK" | grep -qE '^AKIA[0-9A-Z]{16}$' || {
  echo "ABORT: the test secret does not match the credential class this probe plants;" >&2
  echo "       a plant the gate cannot match would make every case below vacuous." >&2
  exit 2
}

GITE="p@example"".invalid"
BAD=0
mkdir -p "$SRC"
git -C "$SRC" init -q -b main
git -C "$SRC" config user.name probe
git -C "$SRC" config user.email "$GITE"
printf 'plain text\n' > "$SRC/README.md"
printf 'aws_access_key_id = %s\n' "$MARK" > "$SRC/credentials.txt"
git -C "$SRC" add -A && git -C "$SRC" commit -qm "add credentials"
git -C "$SRC" rm -q credentials.txt && git -C "$SRC" commit -qm "remove credentials"   # HEAD is spotless

# case <id> <dir> <want> <what-happened>
#   want: leak        -> exit 1 with a history finding, and NOT skipped/shallow
#         shallow     -> exit 1 with shallow-history, and no history finding (the window is why)
#         notscanned  -> exit 1 with history-not-scanned
#         incomplete  -> exit 1 with history-incomplete (objects the scan could not read)
case_run() {
  local id="$1" dir="$2" want="$3" rc log problem=""
  log="$SB/$id.log"
  LC_ALL="${LC_ALL:-C}" COFA_REQUIRE_HISTORY=1 "${BASH:-bash}" "$GATE" "$dir" >"$log" 2>&1
  rc=$?
  local histf shallow notscan incomplete
  histf="$(grep -cE '^  FAIL +history:' "$log" 2>/dev/null || true)"
  shallow="$(grep -c 'shallow-history' "$log" 2>/dev/null || true)"
  notscan="$(grep -c 'history-not-scanned' "$log" 2>/dev/null || true)"
  incomplete="$(grep -c 'history-incomplete' "$log" 2>/dev/null || true)"

  case "$want" in
    leak)
      [ "$rc" -eq 1 ] || problem="gate exit $rc, expected 1 (a leak in history must fail the gate)"
      [ "${histf:-0}" -ge 1 ] || problem="${problem:-no history finding printed — the history scan did not run}"
      [ "${shallow:-0}" -eq 0 ] || problem="${problem:-unexpectedly reported the clone as shallow}"
      ;;
    shallow)
      [ "$rc" -eq 1 ] || problem="gate exit $rc, expected 1 (a truncated history must fail the gate)"
      [ "${shallow:-0}" -ge 1 ] || problem="${problem:-no shallow-history finding}"
      [ "${histf:-0}" -eq 0 ] || problem="${problem:-found the plant outside the shallow window — the window is deeper than one commit}"
      ;;
    notscanned)
      [ "$rc" -eq 1 ] || problem="gate exit $rc, expected 1 under COFA_REQUIRE_HISTORY=1"
      [ "${notscan:-0}" -ge 1 ] || problem="${problem:-no history-not-scanned finding: a bare repo read GREEN}"
      ;;
    incomplete)
      [ "$rc" -eq 1 ] || problem="gate exit $rc, expected 1 (objects the scan could not read must fail the gate)"
      [ "${incomplete:-0}" -ge 1 ] || problem="${problem:-no history-incomplete finding: a clone with missing objects read GREEN}"
      ;;
  esac

  if [ -z "$problem" ]; then
    case "$want" in
      leak)       echo "H-$id: PASSED  exit 1, credential found in history (the working tree is spotless)" ;;
      shallow)    echo "H-$id: PASSED  exit 1, shallow-history reported and the window could not see the plant" ;;
      notscanned) echo "H-$id: PASSED  exit 1, history-not-scanned reported under COFA_REQUIRE_HISTORY=1" ;;
      incomplete) echo "H-$id: PASSED  exit 1, history-incomplete reported: objects were missing and unreadable" ;;
    esac
  else
    echo "H-$id: FAILED  $problem"
    sed 's/^/       | /' <(grep -E '^  (FAIL|ok) ' "$log" | head -8) 2>/dev/null || true
    BAD=$((BAD + 1))
  fi
}

# ---- H-FULL: positivity control — the plant IS visible to a normal clone --------------
git clone -q "$SRC" "$SB/full" 2>/dev/null
case_run FULL "$SB/full" leak

# ---- H-SHALLOW: history truncated, the plant is outside the window --------------------
git clone -q --depth 1 "file://$SRC" "$SB/shallow" 2>/dev/null
case_run SHALLOW "$SB/shallow" shallow

# ---- H-WORKTREE: .git is a FILE — the old `[ -d "$dir/.git" ]` skipped history here ----
git -C "$SRC" worktree add -q "$SB/wt" HEAD 2>/dev/null
case_run WORKTREE "$SB/wt" leak

# ---- H-BARE: no working tree — must be a finding under strict history mode ------------
git clone -q --mirror "$SRC" "$SB/bare.git" 2>/dev/null
case_run BARE "$SB/bare.git" notscanned

# ---- H-PARTIAL: blobless clone whose remote is gone — objects the scan cannot read ----
git -C "$SRC" config uploadpack.allowFilter true
git -C "$SRC" config uploadpack.allowAnySHA1InWant true
git clone -q --filter=blob:none "file://$SRC" "$SB/partial" 2>/dev/null
git -C "$SB/partial" remote set-url origin "file://$SB/no-such-remote"
# Prove the fixture is PARTIAL before asserting anything: a filtered clone silently degrades to a
# full one when the source lacks uploadpack.allowFilter, and then this state would pass vacuously.
# Counted before anything else touches the objects — --missing=print does not trigger a lazy fetch.
PARTIAL_MISSING="$(git -C "$SB/partial" rev-list --objects --missing=print --all 2>/dev/null | grep -c '^?' || true)"
[ "${PARTIAL_MISSING:-0}" -ge 1 ] || {
  echo "ABORT: H-PARTIAL fixture is not partial (is uploadpack.allowFilter set on the source?)" >&2
  exit 2
}
case_run PARTIAL "$SB/partial" incomplete

if [ "$BAD" -eq 0 ]; then
  echo "HISTORY-STATE: PASSED (5 of 5 states behave)"
  exit 0
fi
echo "HISTORY-STATE: FAILED ($BAD of 5 states misbehaved — these behaviours are unguarded)"
exit 1
