#!/usr/bin/env bash
# Continuity — verification.
#
# Contract: exit 0 ONLY when a checkpoint written before a restart is what a woken session
# can actually recover. Prose about "read the file first" is not evidence; a cold process
# reading a real file is.
#
# Non-vacuity: phase 0 re-runs this script with an EMPTY config dir and requires FAILURE,
# and phases 5-6 break the input (IDLE phase, cleared file) and require the consumer to refuse.
#
# Deployed config: ${COFA_CONFIG_DIR:-$HOME/.config/cofa}/continuity/config.yaml
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
CLIENT="$COMPONENT_DIR/lib/checkpoint.py"
SAMPLE="$COMPONENT_DIR/config.sample.yaml"
CONFIG_DIR="${COFA_CONFIG_DIR:-$HOME/.config/cofa}"
CONFIG="$CONFIG_DIR/continuity/config.yaml"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "=== Continuity Verify ==="
echo "config: $CONFIG"

if ! command -v python3 >/dev/null 2>&1; then
  echo "REQUIREDCHECK python3: continuity's client and verifier are Python 3.9+ scripts."
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

# ------------------------------------------------------------------ phase 1: shipped sample
if [ -f "$SAMPLE" ] && grep -q 'resume_file' "$SAMPLE" && grep -q 'checkpoints_dir' "$SAMPLE"; then
  pass "shipped sample config documents resume_file and checkpoints_dir"
else
  fail "config.sample.yaml is missing required fields (resume_file / checkpoints_dir)"
fi

# ------------------------------------------------------------------ phase 2: deployed config
if [ ! -f "$CONFIG" ]; then
  fail "no deployed config at $CONFIG — the component is not installed"
  echo "REQUIREDCHECK cofa-continuity-config: copy config.sample.yaml there and set resume_file + checkpoints_dir."
elif python3 "$CLIENT" --config "$CONFIG" resolve >/dev/null 2>"$TMP/dep.err"; then
  pass "deployed config loads and a checkpoint is currently resumable"
elif grep -q 'USAGE' "$TMP/dep.err"; then
  fail "deployed config is unusable: $(tail -1 "$TMP/dep.err")"
else
  # A valid config with nothing (or an IDLE checkpoint) to resume is a normal state, not a defect.
  pass "deployed config loads (nothing resumable right now: $(tail -1 "$TMP/dep.err"))"
fi

# ------------------------------------------------------------------ functional phases
# Everything below runs against a temp HOME + temp paths, so the verifier never touches the
# deployed state and never writes into the checkout (S1/S8).
HOME_TMP="$TMP/home"
mkdir -p "$HOME_TMP"
CFG="$TMP/config.yaml"
cat > "$CFG" <<YAML
checkpoints_dir: "$HOME_TMP/cofa/checkpoints/"
resume_file: "$HOME_TMP/cofa/resume/LAST_TASK.md"
auto_resume_phase: "ACTIVE"
checkpoint_interval_seconds: 300
format: json
YAML

if python3 "$CLIENT" --config "$CFG" save --title "verify task" --state "mid-build" --next "finish the verifier" >"$TMP/save.out" 2>&1; then
  pass "save writes a checkpoint: $(cat "$TMP/save.out")"
else
  fail "save failed (exit $?): $(cat "$TMP/save.out")"
fi

RESUME="$HOME_TMP/cofa/resume/LAST_TASK.md"
if [ -s "$RESUME" ] && python3 -c "import json,sys; json.load(open('$RESUME'))" 2>/dev/null; then
  pass "checkpoint file exists at the configured path and is valid JSON"
else
  fail "checkpoint file missing or not valid JSON at $RESUME"
fi

SNAPSHOTS="$(find "$HOME_TMP/cofa/checkpoints" -name '*.json' 2>/dev/null | wc -l)"
if [ "$SNAPSHOTS" -ge 1 ]; then
  pass "history snapshot written to checkpoints_dir ($SNAPSHOTS file)"
else
  fail "no snapshot in checkpoints_dir — a single overwritten file is not history"
fi

# Cold consumer path: a brand-new process must recover the fields (this is the restart test).
python3 "$CLIENT" --config "$CFG" resolve >"$TMP/resolve.out" 2>"$TMP/resolve.err"
rc=$?
RECOVERED="$(tail -1 "$TMP/resolve.out" 2>/dev/null)"
if [ "$rc" -eq 0 ] && echo "$RECOVERED" | grep -q '"title": "verify task"' \
   && echo "$RECOVERED" | grep -q '"state": "mid-build"' \
   && echo "$RECOVERED" | grep -q '"next": "finish the verifier"'; then
  pass "cold resolve recovers title, state and next step"
else
  fail "cold resolve did not recover the checkpoint fields (exit $rc): $RECOVERED"
fi

# --------------------------------------------------------------- negative: IDLE phase
python3 "$CLIENT" --config "$CFG" save --title "idle task" --state s --next n --phase IDLE >/dev/null 2>&1
python3 "$CLIENT" --config "$CFG" resolve >"$TMP/idle.out" 2>"$TMP/idle.err"
rc=$?
if [ "$rc" -eq 1 ] && grep -q 'phase is IDLE' "$TMP/idle.err"; then
  pass "negative test: an IDLE checkpoint is refused for auto-resume (exit 1)"
else
  fail "negative test: IDLE checkpoint was not refused cleanly (exit $rc): $(tail -1 "$TMP/idle.err")"
fi

# --------------------------------------------------------------- negative: cleared file
python3 "$CLIENT" --config "$CFG" clear >/dev/null 2>&1
python3 "$CLIENT" --config "$CFG" resolve >"$TMP/clear.out" 2>"$TMP/clear.err"
rc=$?
if [ "$rc" -eq 1 ] && grep -qi 'no checkpoint file' "$TMP/clear.err" && [ ! -f "$RESUME" ]; then
  pass "negative test: cleared checkpoint → resolve refuses (exit 1) and the file is gone"
else
  fail "negative test: cleared checkpoint still resolves (exit $rc): $(tail -1 "$TMP/clear.err")"
fi

# --------------------------------------------------------------- path expansion ('~' in YAML)
tilde_cfg="$TMP/tilde.yaml"
cat > "$tilde_cfg" <<'YAML'
checkpoints_dir: "~/cofa_verify/checkpoints/"
resume_file: "~/cofa_verify/resume/LAST_TASK.md"
auto_resume_phase: "ACTIVE"
YAML
HOME="$HOME_TMP" python3 "$CLIENT" --config "$tilde_cfg" save --title t --state s --next n >/dev/null 2>&1
if [ -f "$HOME_TMP/cofa_verify/resume/LAST_TASK.md" ]; then
  pass "'~' in the config is expanded against HOME (no literal '~' directory created)"
else
  fail "'~' was not expanded — checkpoints landed outside HOME (S7 regression)"
fi

# ------------------------------------------------------------------ summary
echo ""
echo "Results: $PASS passed  $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "STATUS: FAILED — continuity is NOT operational on this machine."
  exit 1
fi
echo "STATUS: PASSED — a checkpoint survives a cold read and phase discipline is enforced."
exit 0
