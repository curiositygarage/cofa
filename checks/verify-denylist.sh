#!/bin/bash
# Usage: checks/verify-denylist.sh [path/to/scan-sanitisation.sh]
#
# Does the operator denylist ACTUALLY catch what each entry was written for?
#
# "All 11 classes asserted clean" only says the entries did NOT fire on this tree. It says nothing
# about whether they WOULD fire. This prover answers that without printing a private string: the
# canaries live in checks/denylist.local (git-ignored, excluded from every scan) as `#canary <text>`
# comment lines, and the gate skips `#` lines everywhere it reads that file.
#
# Three required properties:
#   1. every entry has at least one canary that matches it   (coverage is proven, not asserted)
#   2. every canary matches at least one entry               (a canary matching nothing is a typo)
#   3. the gate flags every canary: each is planted as a file in a throwaway checkout and must
#      produce one denylist finding — so the entry works end to end, not just as a regex.
#
# exit 0 = all three hold, 1 = at least one problem, 2 = usage/denylist missing.
set -uo pipefail
LC_ALL=C; export LC_ALL

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="${1:-$ROOT/bin/scan-sanitisation.sh}"
[ -d "$GATE" ] && GATE="$GATE/bin/scan-sanitisation.sh"
[ -x "$GATE" ] || { echo "usage: $0 [path/to/scan-sanitisation.sh]" >&2; exit 2; }
DL="$ROOT/checks/denylist.local"
[ -f "$DL" ] || { echo "verify-denylist: $DL absent — no operator denylist to prove" >&2; exit 2; }

pats=(); canaries=()
while IFS= read -r line; do
  case "$line" in
    ''|'#'*) ;;                                    # comments (and the canary lines) are not patterns
    *)       pats+=("$line") ;;
  esac
  case "$line" in
    '#canary '*) canaries+=("${line#\#canary }") ;;
  esac
done < "$DL"

bad=0
if [ "${#pats[@]}" -eq 0 ]; then echo "verify-denylist: no entries in $DL" >&2; exit 2; fi
if [ "${#canaries[@]}" -eq 0 ]; then
  echo "verify-denylist: $DL has no '#canary <text>' lines — coverage is asserted, not proven" >&2
  exit 1
fi

# 1. every entry has at least one canary that matches it
i=0
for p in "${pats[@]}"; do
  i=$((i + 1)); hit=0
  for c in ${canaries+"${canaries[@]}"}; do
    printf '%s' "$c" | grep -qE -- "$p" && hit=1 && break
  done
  [ "$hit" -eq 1 ] || {
    echo "  NO CANARY for entry #$i (line $(grep -nxF -- "$p" "$DL" | head -1 | cut -d: -f1)): its coverage is asserted, not proven"
    bad=$((bad + 1))
  }
done

# 2. every canary matches at least one entry (a canary that matches nothing is a typo, not evidence)
j=0
for c in ${canaries+"${canaries[@]}"}; do
  j=$((j + 1)); hit=0
  for p in "${pats[@]}"; do printf '%s' "$c" | grep -qE -- "$p" && hit=1 && break; done
  [ "$hit" -eq 1 ] || { echo "  canary #$j matches NO entry"; bad=$((bad + 1)); }
done

# 3. the GATE flags every canary: plant each as a file in a throwaway checkout and require one finding per canary
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/g/bin" "$T/g/checks" "$T/w"
cp "$GATE" "$T/g/bin/" && chmod +x "$T/g/bin/"*.sh
cp "$DL" "$T/g/checks/"
# the identity below is split so this checker is not itself an email-address finding for the gate it tests
(cd "$T/w" && git init -q -b main . && git config user.name t && git config user.email "t""@""example.invalid" \
  && echo "plain" > README.md
  k=0; for c in ${canaries+"${canaries[@]}"}; do k=$((k + 1)); printf '%s\n' "$c" > "canary_$k.txt"; done
  git add -A && git commit -qm c)
out="$("$T/g/bin/scan-sanitisation.sh" "$T/w" 2>&1)"; rc=$?
flagged=$(printf '%s\n' "$out" | grep -aE '^  FAIL +denylist:' | sed -E 's/.*(canary_[0-9]+\.txt).*/\1/' | sort -u | wc -l | tr -d ' ')
echo "gate on the planted canaries: exit $rc, canary files flagged: $flagged of ${#canaries[@]}"
[ "$rc" -eq 1 ] && [ "$flagged" -eq "${#canaries[@]}" ] || { echo "  the gate did NOT flag every canary"; bad=$((bad + 1)); }

echo
if [ "$bad" -eq 0 ]; then
  echo "DENYLIST: PASSED — every entry has a matching canary and the gate flags each one"
else
  echo "DENYLIST: FAILED ($bad problem(s))"
fi
[ "$bad" -eq 0 ]
