#!/usr/bin/env bash
# gate-redaction-probe.sh — does a failing gate run print the value it found?
#
#   usage:  gate-redaction-probe.sh /path/to/bin/scan-sanitisation.sh
#
# A public CI log is public. If the gate prints the matched line, the secret / path / address it just
# refused to publish is published by the log instead. This plants one leak per shape, runs the gate,
# and requires TWO things for each: the gate FAILS (exit 1), and its output contains NONE of the
# planted marker. Reported per plant as REDACTED / LEAKS VALUE / NOT CAUGHT.
#
# Names are a special case, reported separately (marked "name"): when the finding IS a private file,
# directory, branch or link-target name, printing the name reveals it, and printing nothing leaves the
# reader unable to find it. Decide a policy (mask by default, reveal locally behind an explicit flag)
# and make the expected result below match it.
#
# Like the plant matrix this file may live in the repo: every literal is assembled from parts at
# runtime, so it passes the repository's own gate.
set -u

GATE_SRC="${1:?usage: $0 /path/to/bin/scan-sanitisation.sh}"
[ -f "$GATE_SRC" ] || { echo "no such gate: $GATE_SRC" >&2; exit 3; }
SB="$(mktemp -d)"; W="$SB/work"
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/bin" "$SB/checks"
cp "$GATE_SRC" "$SB/bin/scan-sanitisation.sh"; chmod +x "$SB/bin/scan-sanitisation.sh"

DENY="zqprivate""name"                       # an operator-private string, in the sandbox denylist
printf '%s\n%s\n' "$DENY" "zqsecret[0-9]+" > "$SB/checks/denylist.local"   # one literal entry, one REGEX entry
SK="sk-$(printf 'Q7x9%.0s' {1..8})"          # secret-shaped value (unique run of characters)
HOMEP="/ho""me/zqalice/priv"                 # absolute home path
MAIL="zqbob@corp-mail"".test"                # mail address
GITMAIL="t@example"".invalid"
BAD=0; N=0

fresh() {
  rm -rf "$W"; mkdir -p "$W"; cd "$W" || exit 3
  git init -q -b main . && git config user.name t && git config user.email "$GITMAIL"
  echo "plain text" > README.md; git add -A; git commit -qm base
}
commit() { git add -A >/dev/null 2>&1; git commit -qm "${1:-c}" --allow-empty >/dev/null 2>&1; }

# probe <id> <kind: value|name> <marker> <label>
probe() {
  local id="$1" kind="$2" marker="$3" label="$4" rc v
  LC_ALL=C "$SB/bin/scan-sanitisation.sh" "$W" >"$SB/out.log" 2>&1; rc=$?; N=$((N + 1))
  if [ "$rc" -ne 1 ]; then v="NOT CAUGHT (rc=$rc)"; BAD=$((BAD + 1))
  elif grep -aqF -- "$marker" "$SB/out.log"; then v="LEAKS VALUE"; BAD=$((BAD + 1))
  else v="REDACTED"; fi
  printf '%-4s %-5s %-60s %s\n' "$id" "$kind" "$label" "$v"
}

echo "gate under test: $GATE_SRC"
echo
echo "--- values (the matched text must never be printed)"
fresh; echo "k=$SK" > leak.txt;                                          probe R1  value "$SK"    "secret in a text file"
fresh; echo "k=$SK  # cofa:sanitise-allow" > a.txt; echo "k2=$SK" > b.txt; probe R2  value "$SK"    "allow-marker line printed beside a real finding"
fresh; echo "k=$SK" > old.txt; commit add; git rm -q old.txt; commit rm;  probe R3  value "$SK"    "secret in history (deleted blob)"
fresh; commit "k=$SK";                                                   probe R4  value "$SK"    "secret in a commit message"
fresh; git tag -a v9 -m "k=$SK";                                         probe R5  value "$SK"    "secret in an annotated tag message"
fresh; echo "path $HOMEP/x" > p.txt;                                     probe R6  value "$HOMEP" "absolute home path in a text file"
fresh; echo "to $MAIL" > m.txt;                                          probe R7  value "$MAIL"  "mail address in a text file"
fresh; git config user.email "$DENY@corp-mail"".test"; commit "id";        probe R8  value "$DENY"  "private string in the commit AUTHOR identity"
fresh; echo "k=$SK" > old.txt; commit add; git rm -q old.txt; commit rm
git config user.name "$DENY"; commit "name";                             probe R9  value "$DENY"  "private string in the commit author NAME + a history secret"

echo "--- names (the finding is the name itself; decide a policy)"
fresh; echo ok > "$DENY-notes.md";                                       probe R10 name  "$DENY"  "private string in a file name"
fresh; mkdir -p "$DENY-dir"; echo ok > "$DENY-dir/a.md";                 probe R11 name  "$DENY"  "private string in a directory name"
fresh; git branch "$DENY-wip";                                           probe R12 name  "$DENY"  "private string in a branch name"
fresh; ln -s "$HOMEP/x" lnk;                                             probe R13 name  "$HOMEP" "private path as a symlink target"
fresh; printf 'PAD\0\0x\n' > "$DENY.dat";                                probe R14 name  "$DENY"  "private string in the name of a binary file"

echo "--- round 3: where the locator is built from message text, and keys that are themselves names"
fresh; git commit -q --allow-empty -m "release notes" -m "k=$SK";           probe R15 value "$SK"    "secret on a LATER line of a multi-line commit message"
fresh; git commit -q --allow-empty -m "subject" -m "$SK is the key";        probe R16 value "$SK"    "secret as the FIRST word of a commit-message body line"
fresh; git tag -a v9 -m "release" -m "$SK";                                 probe R17 value "$SK"    "secret in the BODY of an annotated tag"
fresh; mkdir -p a2a-mesh; printf 'peers:\n  zqpeerone:\n    endpoint: "http://x"\n' > a2a-mesh/config.sample.yaml
                                                                             probe R18 name  "zqpeerone" "non-placeholder peer key in config.sample.yaml"
fresh; echo ok > "zqsecret42-notes.md";                                      probe R19 name  "zqsecret42" "file name matching a denylist REGEX entry"

echo
# R20 (round 11, external review): a tree that holds exactly ONE file. `grep -n` prints the file name
# only when it has more than one file to name, so a single-file tree is the shape where the matched
# TEXT is printed unfiltered — the redaction half of the gate's contract, in its narrowest case.
fresh; git rm -q README.md; echo "k=$SK" > only.txt; commit "one file";     probe R20 value "$SK"    "secret in a tree that holds exactly ONE file (grep drops the filename column)"

echo "probes run: $N   problems: $BAD"
[ "$BAD" -eq 0 ] && echo "REDACTION: PASSED" || echo "REDACTION: FAILED — $BAD probe(s) printed a value or missed the leak"
exit $([ "$BAD" -eq 0 ] && echo 0 || echo 1)
