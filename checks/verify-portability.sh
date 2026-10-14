#!/usr/bin/env bash
# checks/verify-portability.sh — the repo must run on bash 3.2, the version macOS still ships.
#
# WHY THIS EXISTS: the gate is the first thing a cloner runs, and it used `mapfile` — a bash 4
# builtin. On a stock Mac that is "mapfile: command not found" and the gate dies before scanning a
# single file, i.e. the security tool fails OPEN on exactly the machines least likely to notice.
# An external reviewer flagged it; this check makes it a permanent, testable property instead of a
# thing someone remembered once. A second reviewer proved the first version was too narrow — it
# knew 10 constructs and only ever opened `*.sh` — so the list below is the constructs we know of
# that exist in bash 4/5 and are absent or different in 3.2. It is a list, not a proof of
# completeness: a construct nobody has hit yet is not in it. Files are found by shebang, not by name,
# because a real script can be extensionless (git hook samples, cron.d entries, vendored files).
#
# WHAT IT SCANS: every shell file, not only `*.sh`. A file is shell if its name ends in .sh OR its
# FIRST LINE names a shell (bash/sh/ksh/dash/zsh, i.e. a #! line). The shebang branch exists
# because a real script can be extensionless — git hook samples, cron.d entries, anything vendored
# in from elsewhere — and a name-based scan never opens those, so a bash-4 builtin inside one ships
# silently. Local backup noise (*.orig, *.bak, *~ — what .gitignore keeps out of the repo) is
# skipped: it is not a shipped artifact.
#
# KNOWN BLIND SPOTS — this is a static pattern check, never a runner:
#   · Runtime-only differences are invisible here. Two are documented in SANITISATION.md: under
#     3.2 the double-quoted replacement in ${s//"$p"/"$(masked …)"} keeps its quote characters
#     (cosmetic, still redacted), and "${a[@]}" on an empty array trips `set -u` before 4.4.
#   · It matches by LINE, so a construct inside a comment or a quoted example is flagged too. That
#     direction is deliberate: a false alarm costs a look, a miss costs the gate.
#   · Only the literal spelling is chased (`command mapfile` is not).
#
#   ./checks/verify-portability.sh            scan this repo (default)
#   ./checks/verify-portability.sh <dir>...   scan given roots
#   ./checks/verify-portability.sh --selftest prove THIS check can fail
#
# Exit: 0 clean · 1 findings · 2 usage or nothing to scan (never read as clean)
#
# The scan deliberately skips itself (see find_shell) — its own pattern text contains the
# constructs, and its own shebang branch would otherwise report itself.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

# label|extended-regex. Every entry is a construct that is silently absent or different on bash 3.2.
PATTERNS=(
  'mapfile|(^|[^A-Za-z_])mapfile[[:space:]]'
  'readarray|(^|[^A-Za-z_])readarray[[:space:]]'
  'declare -A|declare[[:space:]]+-A'
  'local -A|local[[:space:]]+-A'
  'append-redirect|&>>'
  'upper-case-expansion|\$\{[A-Za-z_][A-Za-z0-9_]*\^\^\}'
  'lower-case-expansion|\$\{[A-Za-z_][A-Za-z0-9_]*,,\}'
  'globstar|shopt[[:space:]]+-s[[:space:]]+globstar'
  'test -v|\[\[[[:space:]]+-v[[:space:]]'
  'coproc|(^|[^A-Za-z_])coproc[[:space:]]'
  # --- the 3.2-incompatible class the first version could not see: one entry per spelling ---
  'case-fallthrough|(^|[^;]);&'                    # ;& (4.0): fall through a case clause
  'case-continue|;;&'                              # ;;& (4.0): re-test the next case pattern
  'pipe-stderr|\|&'                                # |& (4.0): pipe stdout and stderr together
  'nameref|(declare|local)[[:space:]]+-n'          # -n (4.3): by-reference variables
  'declare -g|declare[[:space:]]+-g([[:space:]]|$)'  # -g (4.2): assign in global scope
  'declare -gA|declare[[:space:]]+-gA'             # -gA (4.2): global associative array
  'negative-index|\[[[:space:]]*-[0-9]+\]'         # a[-1] (4.3): index counted from the end
  'fractional read -t|read[[:space:]]+-[a-zA-Z]*t[[:space:]]+[0-9]*\.[0-9]'   # read -t 0.5 (4.0)
  'wait -n|(^|[^A-Za-z_])wait[[:space:]]+-n([[:space:]]|$)'                    # -n (4.3)
  'printf %()T|%\([^)]*\)T'                        # %(%Y-%m-%d)T (4.2): strftime inside printf
  'parameter @-transform|\$\{[A-Za-z_][A-Za-z0-9_]*@[A-Za-z]'                  # ${v@Q} (4.4)
  'EPOCHSECONDS|(^|[^A-Za-z_])EPOCH(SECONDS|REALTIME)'                         # (5.0)
  'shopt lastpipe|shopt[[:space:]]+-s[[:space:]]+lastpipe'                     # (4.2)
  'shopt inherit_errexit|shopt[[:space:]]+-s[[:space:]]+inherit_errexit'       # (4.4)
  'upper-case-first|\$\{[A-Za-z_][A-Za-z0-9_]*\^\}'        # ${v^} (4.0) — distinct from ${v^^}
  'test -R|\[\[[[:space:]]+-R[[:space:]]'                  # [[ -R ]] (4.3): "is a name reference"
)

is_backup() {   # is_backup <path>   — .gitignore's backup noise; not a shipped artifact
  case "$1" in
    *.orig|*.orig-*|*.bak|*.bak-*) return 0 ;;
  esac
  case "$1" in
    *~) return 0 ;;
  esac
  return 1
}

is_shell_line() {   # is_shell_line <first-line>   — the shell must be a word: #!/usr/bin/env bash
  printf '%s\n' "$1" | grep -qE '^#!.*(^|[^[:alnum:]])(bash|sh|ksh|dash|zsh)([^[:alnum:]]|$)'
}

find_shell() {   # find_shell <root>...  — portable: no -printf, no mapfile, no arrays-as-sets
  local r f shb
  for r in "$@"; do
    find "$r" -type f \
      -not -path '*/.git/*' \
      -not -name 'verify-portability.sh' 2>/dev/null |
    while IFS= read -r f; do
      if is_backup "$f"; then continue; fi
      case "$f" in
        *.sh) printf '%s\n' "$f"; continue ;;
      esac
      shb=$(sed -n '1p' "$f" 2>/dev/null)          # no `read < file` here: it is easy to steal the
      if [ -n "$shb" ] && is_shell_line "$shb"; then printf '%s\n' "$f"; fi   # outer loop's stdin
    done
  done
}

scan() {   # scan <root>...  -> findings on stdout, count in SCANNED / BAD
  SCANNED=0; BAD=0
  local f entry label re hits
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    SCANNED=$((SCANNED + 1))
    for entry in "${PATTERNS[@]}"; do
      label="${entry%%|*}"; re="${entry#*|}"
      hits=$(grep -nE -- "$re" "$f" 2>/dev/null)
      if [ -n "$hits" ]; then
        printf '  ✗ bash-4-only [%s] %s\n' "$label" "$f"
        printf '%s\n' "$hits" | sed 's/^/        /'
        BAD=$((BAD + 1))
      fi
    done
  done < <(find_shell "$@" | sort)

  if [ "$SCANNED" -eq 0 ]; then
    printf 'FATAL: no shell files found under: %s\n' "$*" >&2
    return 2
  fi
  if [ "$BAD" -ne 0 ]; then
    return 1
  fi
  return 0
}

# ---- selftest: the check must be able to FAIL ------------------------------------------------
if [ "${1:-}" = "--selftest" ]; then
  tmp=$(mktemp -d) || exit 2
  trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/bad" "$tmp/good"

  # One construct per file. Every line of the list must be reachable, so the shapes that the first
  # version was blind to get a file of their own — including an EXTENSIONLESS one, which only the
  # shebang branch can find.
  printf '#!/usr/bin/env bash\nmapfile -t X < <(echo hi)\n' > "$tmp/bad/uses-mapfile.sh"
  printf '#!/usr/bin/env bash\ncase $x in a) : ;& b) : ;; esac\n' > "$tmp/bad/uses-fallthrough.sh"
  printf '#!/usr/bin/env bash\nlocal -n ref=VAR\nX=${V^^}\n' > "$tmp/bad/uses-nameref.sh"
  printf '#!/usr/bin/env bash\necho "$EPOCHSECONDS"\n' > "$tmp/bad/uses-epoch.sh"
  printf '#!/usr/bin/env bash\nX=${V^}\n[[ -R x ]]\n' > "$tmp/bad/uses-caret.sh"
  printf '#!/usr/bin/env bash\nwait -n\n' > "$tmp/bad/hook"

  printf '#!/usr/bin/env bash\nX=()\nwhile IFS= read -r l; do X+=("$l"); done < <(echo hi)\n' \
    > "$tmp/good/portable.sh"
  printf '#!/bin/sh\nexec ./gate\n' > "$tmp/good/hook-ok"          # extensionless, and portable
  # Not a shell file: a name-based AND a shebang-based scan must both leave it alone, even though
  # it contains the constructs verbatim.
  printf '#!/usr/bin/env python3\nS = "mapfile -t X ;& ${V^} wait -n [[ -R x ]]"\n' \
    > "$tmp/good/notes.py"

  bad_out=$(scan "$tmp/bad" 2>/dev/null); rc_bad=$?
  good_out=$(scan "$tmp/good" 2>/dev/null); rc_good=$?

  why=""
  [ "$rc_bad" -eq 1 ] || why="bad dir: exit $rc_bad (want 1)"
  [ "$rc_good" -eq 0 ] || why="${why:+$why; }good dir: exit $rc_good (want 0)"
  if [ -z "$why" ]; then
    printf '%s\n' "$bad_out" | grep -q '/bad/hook$' ||
      why="the extensionless 'hook' was not scanned — the shebang branch is not doing the work"
  fi
  if [ -z "$why" ]; then
    printf '%s\n' "$good_out" | grep -q 'notes.py' &&
      why="notes.py (python, not shell) was scanned — the shebang filter is too loose"
  fi

  if [ -z "$why" ]; then
    echo "SELFTEST PASSED — flags bash-4 constructs incl. an extensionless script (exit 1),"
    echo "                  passes the portable equivalents and skips non-shell files (exit 0)"
    exit 0
  fi
  echo "SELFTEST FAILED — $why" >&2
  echo "A portability check that cannot fail is worse than none." >&2
  exit 1
fi

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  echo "usage: $0 [dir ...] | --selftest"
  echo "Semantics: 0 clean · 1 bash-4-only construct found · 2 nothing to scan"
  echo "Scans: *.sh plus any file whose first line names a shell; skips *.orig/*.bak/*~"
  exit 2
fi

roots=("$@")
if [ "${#roots[@]}" -eq 0 ]; then roots=("."); fi

echo "portability: bash-3.2 (macOS default) constructs"
scan "${roots[@]}"
rc=$?
if [ "$rc" -eq 2 ]; then exit 2; fi      # nothing to scan is never a pass
# rc 1 = findings; fall through and report them in full

if [ "$BAD" -ne 0 ]; then
  printf '\nportability: %d problem(s) across %d file(s)\n' "$BAD" "$SCANNED"
  printf 'STATUS: FAILED — these break on bash 3.2, which macOS ships as /bin/bash.\n'
  exit 1
fi

printf 'portability: clean — %d file(s) scanned, no bash-4-only construct\n' "$SCANNED"
exit 0
