#!/usr/bin/env bash
# COFA profiles — verification.
#
# Contract: the DEFAULT profile installs a tree with no peer lane, and the profiles agree with
# the repo's own docs about which components are optional. Both directions are tested: the solo
# tree must be clean, and the same detector must fire on the mesh component (positive control),
# so a clean result cannot be a dead grep.
#
# exit 0 pass · 1 fail · 2 required tool missing
set -uo pipefail

export PYTHONDONTWRITEBYTECODE=1
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "=== COFA Profiles Verify ==="

for t in bash grep cp; do
  command -v "$t" >/dev/null 2>&1 || { echo "REQUIREDCHECK $t"; exit 2; }
done

# ---------------------------------------------------------------- profile files exist and parse
if [ -f "$ROOT/profiles/solo.txt" ] && [ -f "$ROOT/profiles/mesh.txt" ]; then
  pass "both profiles exist (solo, mesh)"
else
  fail "missing profiles/solo.txt or profiles/mesh.txt"
fi

SOLO_LIST="$(grep -vE '^[[:space:]]*(#|$)' "$ROOT/profiles/solo.txt" | tr '\n' ' ')"
MESH_LIST="$(grep -vE '^[[:space:]]*(#|$)' "$ROOT/profiles/mesh.txt" | tr '\n' ' ')"

case " $SOLO_LIST " in
  *" a2a-mesh "*) fail "solo profile includes a2a-mesh - the default must not ship a peer lane" ;;
  *) pass "solo profile excludes a2a-mesh" ;;
esac
case " $MESH_LIST " in
  *" a2a-mesh "*) pass "mesh profile includes a2a-mesh (opt-in is possible)" ;;
  *) fail "mesh profile does not include a2a-mesh - the opt-in lane is unreachable" ;;
esac

for c in $SOLO_LIST; do
  [ -d "$ROOT/$c" ] && [ -f "$ROOT/$c/README.md" ] || fail "solo component '$c' is not a real component dir"
done
pass "every solo component resolves to a directory with a README"

# ---------------------------------------------------------------- the default really is solo
DEST="$TMP/install"
if bash "$ROOT/bin/install-profile.sh" --dest "$DEST" >"$TMP/install.out" 2>&1; then
  pass "install-profile.sh installs with no --profile flag (default = solo)"
else
  fail "install-profile.sh failed on the default profile: $(tail -2 "$TMP/install.out")"
fi

if [ -f "$DEST/PROFILE" ] && grep -q '^profile: solo' "$DEST/PROFILE"; then
  pass "installed tree records profile: solo"
else
  fail "installed tree has no PROFILE record naming solo"
fi

if [ -d "$DEST/a2a-mesh" ]; then
  fail "default install produced a2a-mesh/ - the peer lane shipped to a solo owner"
else
  pass "default install produced no a2a-mesh/ directory"
fi

# ---------------------------------------------------------------- detector, both directions
PEER_RE='\ba2a\b|agent[ _-]?mesh|allowed_flows|peers\.json'
if grep -rqiE "$PEER_RE" "$DEST" --exclude=PROFILE 2>/dev/null; then
  fail "solo install still mentions a peer lane: $(grep -rliE "$PEER_RE" "$DEST" | head -3 | tr '\n' ' ')"
else
  pass "solo install tree greps clean for peer-lane terms"
fi

# Positive control: the same pattern over the mesh component MUST hit, or the clean result
# above proves nothing but a broken regex.
if grep -rqiE "$PEER_RE" "$ROOT/a2a-mesh" 2>/dev/null; then
  pass "positive control: the peer-lane detector fires on a2a-mesh/"
else
  fail "positive control dead: the detector found nothing in a2a-mesh/, so the clean result is meaningless"
fi

# ---------------------------------------------------------------- docs agree with the code
if [ -f "$ROOT/SETUP-GUIDE.md" ]; then
  # Scoped to Option B only: Option C legitimately documents the opt-in install, so a range that
  # ran to the end of the file would fail on the correct text.
  if awk '/^## Option B/{f=1;next} /^## /{f=0} f' "$ROOT/SETUP-GUIDE.md" | grep -qi 'install a2a-mesh'; then
    fail "SETUP-GUIDE's default install path still tells the owner to install a2a-mesh"
  else
    pass "SETUP-GUIDE's default install path does not install a2a-mesh"
  fi
  if grep -qi 'peer lane' "$ROOT/SETUP-GUIDE.md"; then
    pass "SETUP-GUIDE names the peer lane as a separate, opt-in choice"
  else
    fail "SETUP-GUIDE never names the peer lane as opt-in - the opt-out is undiscoverable"
  fi
else
  fail "SETUP-GUIDE.md missing"
fi

echo ""
echo "Results: $PASS passed  $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "STATUS: FAILED - the default profile does not hold."
  exit 1
fi
echo "STATUS: PASSED - default is solo, the peer lane is opt-in, and the detector is live."
exit 0
