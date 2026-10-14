#!/usr/bin/env bash
# gate-plant-matrix.sh (v4) — does the sanitisation gate actually FAIL on each leak shape?
#
#   usage:  gate-plant-matrix.sh /path/to/bin/scan-sanitisation.sh
#           MATRIX_LOCALE=en_US.UTF-8 gate-plant-matrix.sh ...     (override the locale the gate runs in)
#
# For every plant it builds a throwaway git repo, plants ONE leak, runs the gate on it, and reports
# CAUGHT (gate exit 1) / MISSED (exit 0) / ERROR (exit >= 2). Nothing in your repo is touched: the
# gate is copied into a sandbox root so a private denylist (a fake string) can be placed beside it.
#
# Exit 0 only if every plant that SHOULD be caught was caught and both controls behaved.
# Plants marked "expect-miss" are documented limits or design decisions: they are shown (MISSED*)
# so nobody forgets them, but they do not fail the run.
#
# This file is meant to live IN the repository it tests, so it must pass that repository's own gate:
# every address, path and key shape below is assembled from parts at runtime and never appears as a
# scannable literal. (Adjacent quoted strings concatenate; the quote in the middle breaks the match.)
#
# v2 over v1: the gate now runs in a UTF-8 locale (a real user's locale), and seven plants cover holes
# found in the first fix round: locale-dependent text/binary disagreement (L1/L2), history that holds
# a link or a file NAME (H1/H2), a dot-prefixed path skipped by the name scan (D1/D2), and a relative
# symlink that leaves the tree (S1).
#
# v4 over v3: three plants (W1-W3) for the round-10 fix. A `git worktree add` checkout has a REGULAR
# FILE named .git holding `gitdir: <absolute path>`, and that path is a real home path — so the tree
# scan reported the operator's own worktree as a leak. Round 10 excluded regular files named .git from
# the content/archive/binary finds. W1 pins that (the pointer file itself must not alarm), W2 proves the
# exclusion does not blind the gate to a leak beside it, and W3 proves it does not extend to a SYMLINK
# named .git — the one case that must stay inside the symlink scan.
#
# v5 over v4: three plants (W4-W6) for the round-15 review. W6 is the nested case — a submodule-style
# sub/.git pointer file — which is what separates an exclusion by NAME from an exclusion that only
# covers a root-level .git; W4/W5 plant a secret and a private host in .gitignore/.gitmodules, the
# files a widened `.git*` glob would drop from every content scan.
set -u

GATE_SRC="${1:?usage: $0 /path/to/bin/scan-sanitisation.sh}"
[ -f "$GATE_SRC" ] || { echo "no such gate: $GATE_SRC" >&2; exit 3; }
SB="$(mktemp -d)"; W="$SB/work"
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/bin" "$SB/checks"
cp "$GATE_SRC" "$SB/bin/scan-sanitisation.sh"; chmod +x "$SB/bin/scan-sanitisation.sh"
DENY="zqprivate""name"                      # stands in for an operator's private string
printf '%s\n' "$DENY" > "$SB/checks/denylist.local"
SK="sk-$(printf 'A1b2%.0s' {1..8})"         # matches the openai-key class
TSIP="100.""101.102.103"                    # tailscale-class address
LAN="192.168"".4.9"                         # private-class address
HOMEP="/ho""me/alice"                       # absolute home path
MAIL="bob@corp-mail"".test"                 # mail address
GITMAIL="t@example"".invalid"
BAD=0; N=0

# The locale the gate runs in. A gate that only works under LC_ALL=C is not a gate users can run.
LOC="${MATRIX_LOCALE:-$(locale -a 2>/dev/null | grep -iE '^(C|en_US)\.utf-?8$' | head -1)}"
LOC="${LOC:-C}"

fresh() {
  rm -rf "$W"; mkdir -p "$W"; cd "$W" || exit 3
  git init -q -b main . && git config user.name t && git config user.email "$GITMAIL"
  echo "plain text" > README.md; git add -A; git commit -qm base
}
verdict() { LC_ALL="$LOC" "$SB/bin/scan-sanitisation.sh" "$W" >"$SB/out.log" 2>&1; echo $?; }
commit() { git add -A >/dev/null 2>&1; git commit -qm "${1:-c}" --allow-empty >/dev/null 2>&1; }

# check <id> <label> <expect: caught|clean|expect-miss>
check() {
  local id="$1" label="$2" expect="$3" rc v rules
  rc="$(verdict)"; N=$((N + 1))
  rules="$(grep -E '^  FAIL' "$SB/out.log" | awk '{print $2}' | sort -u | cut -c1-22 | tr '\n' ' ')"
  case "$expect:$rc" in
    caught:1)       v="CAUGHT" ;;
    caught:0)       v="MISSED"; BAD=$((BAD + 1)) ;;
    clean:0)        v="clean (ok)" ;;
    clean:1)        v="FALSE ALARM"; BAD=$((BAD + 1)) ;;
    expect-miss:0)  v="MISSED*" ;;
    expect-miss:1)  v="caught (better than expected)" ;;
    *)              v="ERROR rc=$rc"; BAD=$((BAD + 1)) ;;
  esac
  printf '%-4s %-66s %-14s %s\n' "$id" "$label" "$v" "$([ "$rc" = 1 ] && echo "[$rules]")"
}

echo "gate under test: $GATE_SRC"
echo "gate runs with LC_ALL=$LOC"
echo "sandbox denylist entry: $DENY"
echo
echo "--- controls"
fresh;                                                           check C0 "clean tree" clean
fresh; echo "k=$SK" > leak.txt;                                  check C1 "secret in a plain text file" caught

echo "--- the original eight"
fresh; printf 'PAD\0\0k=%s\n' "$SK" > data.dat;                  check P1 "NUL-containing file with a secret" caught
fresh; python3 - "$SK" <<'PY'
import sys, zlib, sqlite3, random
sk = sys.argv[1]; random.seed(1)
txt = ' '.join(''.join(random.choice('abcdefghij') for _ in range(7)) for _ in range(400)) + ' k=' + sk
open('x_zlib.dat', 'wb').write(zlib.compress(txt.encode()))
c = sqlite3.connect('x.db'); c.execute('create table t(k)'); c.execute('insert into t values (?)', (txt,)); c.commit()
PY
                                                                 check P2 "zlib stream + sqlite db holding a secret" caught
fresh; echo "k=$SK" > notes.bak; echo "k=$SK" > old.orig
mkdir -p node_modules/p __pycache__; echo "k=$SK" > node_modules/p/i.js; echo "k=$SK" > __pycache__/x.pyc
                                                                 check P3 "secret in .bak/.orig/node_modules/__pycache__ (excluded-by-name)" caught
fresh; echo "k=$SK" > old.txt; commit add; git rm -q old.txt; commit rm
                                                                 check P4 "secret committed then deleted (history, shallow)" caught
fresh; echo "k=$SK" > old.txt; commit add; git rm -q old.txt; commit rm
for i in $(seq 1 260); do echo "$i" > f.txt; git add f.txt; git commit -qm "c$i"; done
                                                                 check P5 "same secret buried 260 commits deep" caught
fresh; printf 'PAD\0\0k=%s\n' "$SK" > d.dat; commit add; git rm -q d.dat; commit rm
                                                                 check P6 "secret in a BINARY blob in history (deleted at tip)" caught
fresh; printf 'host %s and %s/proj and %s and %s\n' "$TSIP" "$HOMEP" "$MAIL" "$LAN" > t.txt
commit add; git rm -q t.txt; commit rm;                          check P7 "tailscale IP / home path / email / LAN IP in history" caught
fresh; mkdir -p vendor/x; cp -r .git vendor/x/.git;              check P8a "nested .git directory" caught
fresh; mkdir -p vendor/gitdata; cp -r .git/objects .git/refs .git/HEAD vendor/gitdata/
                                                                 check P8b "scrubbed copy of .git under another name (objects+refs+HEAD)" caught

echo "--- neighbours"
fresh; ln -s "$HOMEP/secret-notes" link; commit add;             check N1 "symlink whose TARGET is a private path (find -type f skips links)" caught
fresh; echo "innocent" > "$DENY-notes.md";                       check N2 "denylist string in a FILE NAME (content scans never see names)" caught
fresh; mkdir -p "$DENY-dir"; echo "innocent" > "$DENY-dir/a.md"; check N3 "denylist string in a DIRECTORY name" caught
fresh; commit "k=$SK";                                           check N4 "secret in a commit MESSAGE" caught
fresh; git tag -a v9 -m "k=$SK";                                 check N5 "secret in an annotated TAG message" caught
fresh; git branch "$DENY-wip";                                   check N6 "denylist string in a BRANCH name (published refs)" caught
fresh; echo "$DENY" > f.txt; commit add; git rm -q f.txt; commit rm
                                                                 check N7 "denylist string committed then deleted" caught
fresh; printf 'PAD\0\0%s\n' "$DENY" > b.dat;                     check N8 "denylist string inside a binary file" caught
fresh; printf 'k=%s\n' "$SK" | iconv -f UTF-8 -t UTF-16LE > u16.txt
                                                                 check N9 "secret in a UTF-16LE text file (NULs hide it from grep)" caught
fresh; git bundle create b.bundle --all >/dev/null 2>&1;         check N10 "git bundle of this repository" caught
fresh; mkdir -p .github/workflows; echo "k=$SK" > .github/workflows/x.yml
                                                                 check N11 "secret in a dot-directory" caught
fresh; echo "k=$SK # cofa:sanitise-allow" > a.txt;               check N12 "allow-marker appended to a real secret (marker is trusted)" expect-miss
fresh; printf 'k=sk-A1b2A1b2A1b2\nA1b2A1b2A1b2A1b2\n' > split.txt; check N13 "secret split across two lines (documented limit)" expect-miss

echo "--- found in the first fix round"
fresh; printf 'caf\351 k=%s\n' "$SK" > latin1.txt;               check L1 "invalid-UTF-8 text file with a secret (text under C, binary under UTF-8)" caught
fresh; printf 'caf\351 %s\n' "$DENY" > latin1.txt;               check L2 "invalid-UTF-8 text file holding a denylist string" caught
fresh; ln -s "$HOMEP/x" lnk; commit add; git rm -q lnk; commit rm
                                                                 check H1 "absolute symlink committed then deleted (git grep skips links)" caught
fresh; echo ok > "$DENY-notes.md"; commit add; git mv "$DENY-notes.md" notes.md; commit mv
                                                                 check H2 "private FILE NAME in history, renamed before publish" caught
fresh; mkdir -p ".github/$DENY"; echo ok > ".github/$DENY/x.md"; check D1 "private DIRECTORY name under .github (name scan skips */.git*)" caught
fresh; echo ok > ".git$DENY";                                    check D2 "private name in a file whose name starts with .git" caught
fresh; ln -s ../../../../etc/passwd rel; commit add;             check S1 "relative symlink that leaves the tree (gate says: must stay inside)" caught
fresh; echo "k=$SK # cofa:sanitise-allow" > a.txt; commit add; git rm -q a.txt; echo ok > keep.txt; commit rm
                                                                 check H3 "allow-marker secret in HISTORY, deleted (is it printed like the tree case?)" expect-miss
fresh; commit "k=$SK cofa:sanitise-allow";                       check H4 "allow-marker inside a commit MESSAGE" expect-miss

echo "--- found in round 3: home-path classes the gate has no pattern for"
fresh; echo "cfg at /Us""ers/zqalice/proj/x" > mac.txt;                  check Q1 "macOS home path /Users/<name>/ in a file" caught
fresh; printf '%s\n' "cfg at C:\\Us""ers\\zqalice\\proj" > win.txt;      check Q2 "Windows home path C:\\Users\\<name>\\ in a file" caught
fresh; echo "cfg at /ho""me/Zqalice/proj" > up.txt;                    check Q3 "/home/<Capitalised>/ (the class requires a lowercase first letter)" caught
fresh; echo "cfg at /ho""me/1000/proj" > uid.txt;                      check Q4 "/home/<digit-leading>/ username" caught
fresh; echo "cfg at /ro""ot/.ssh/id_x" > root.txt;                     check Q5 "root user home directory" caught

echo "--- found in round 10: a linked worktree's root .git pointer FILE"
# A worktree checkout cannot be simulated by writing a .git file into a normal repo: in a normal repo
# .git is a DIRECTORY. So these build a real linked worktree, where git itself creates the pointer file.
wt() {
  rm -rf "$SB/main" "$W"; mkdir -p "$SB/main"; cd "$SB/main" || exit 3
  git init -q -b main . && git config user.name t && git config user.email "$GITMAIL"
  echo "plain text" > README.md; git add -A; git commit -qm base
  git worktree add -q "$W" -b wt >/dev/null 2>&1; cd "$W" || exit 3
  [ -f .git ] || { echo "  !! worktree setup failed (.git is not a regular file)"; exit 3; }
}
wt;                                                              check W1 "worktree .git POINTER FILE holding a real home path — not a leak" clean
wt; echo "k=$SK" > real.txt; commit add;                         check W2 "pointer file present AND a real secret beside it (exclusion must not blind)" caught
fresh; rm -rf .git; ln -s "$HOMEP/.ssh" .git
                                                                 check W3 "SYMLINK named .git (the exclusion must not cover links)" caught
fresh; mkdir -p sub; printf 'gitdir: %s/.git/modules/sub\n' "$HOMEP" > sub/.git; commit add
                                                                 check W6 "NESTED sub/.git pointer file holding a real home path — must NOT be reported (exclusion by NAME, not by root position)" clean

echo "--- found in round 15: a .git* name glob would blind the content scan"
# Widening the round-10 exclusion from "regular file named .git" to ".git*" removes .gitignore,
# .gitattributes, .gitmodules and .gitkeep from every content scan. Nothing here planted a secret in
# one, so a mutant with that glob still passed this matrix — the exclusion breadth was unguarded.
#
# Committing these two plants did NOT fix that, and the reason is worth keeping: a committed secret is
# also in HISTORY, and the history scan reads blobs through `git grep` — an exclusion that only narrows
# the TREE find cannot hide it, so the mutant still passed. Both plants are therefore left UNCOMMITTED:
# the leak exists only where the widened glob can blind it. (Round 15 review; same lesson as W6.)
fresh; echo "k=$SK" > .gitignore
                                                                 check W4 "secret in an UNCOMMITTED .gitignore (a .git* glob blinds the tree scan; committing it lets history catch it and hides the mutant)" caught
fresh; printf 'url = https://git.%s/x/y.git\n' "$TSIP" > .gitmodules
                                                                 check W5 "private address in an UNCOMMITTED .gitmodules — publishable text, not a pointer file" caught

echo
echo "plants run: $N   problems: $BAD   (MISSED* = documented limit / design decision, not counted)"
[ "$BAD" -eq 0 ] && echo "MATRIX: PASSED" || echo "MATRIX: FAILED — $BAD plant(s) not handled as required"
exit $([ "$BAD" -eq 0 ] && echo 0 || echo 1)
