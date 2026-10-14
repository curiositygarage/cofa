#!/usr/bin/env bash
# COFA pre-push sanitisation gate — THE single gate for this repository.
#
# Referenced by SANITISATION.md, README.md and SETUP-GUIDE.md. Do not add a second scanner:
# one gate that can fail is worth more than two that cannot.
#
# Contract:
#   exit 0 = clean, push allowed
#   exit 1 = finding(s) — do NOT push; fix or explicitly allowlist each line
#   exit 2 = usage / internal error (including "no files to scan")
#
# Non-vacuity: `--selftest` plants a canary in a temp tree and REQUIRES the scanner to catch it,
# then requires a clean tree to pass. A scanner that cannot fail is a defect, not a guard.
#
# Design: no private literal is ever written into this repository — operator strings (names,
# hostnames, peer ids, private paths) live in checks/denylist.local, which is git-ignored. This
# file ships pattern CLASSES only. A line that must legitimately mention a forbidden class carries
# the marker `cofa:sanitise-allow`.
#
# Usage: bin/scan-sanitisation.sh [--selftest] [path]

set -uo pipefail
# One locale for every grep in this file. Under a UTF-8 locale grep -I calls a file with an invalid byte
# binary and SKIPS it, while the binary rule below (LC_ALL=C) calls the same file text and does not refuse it:
# each check assumed the other covered it (matrix plants L1/L2). Every pattern here is ASCII, so C is safe.
export LC_ALL=C

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DENYLIST="$ROOT/checks/denylist.local"
ALLOW='cofa:sanitise-allow'
SELFTEST=false
SCAN_PATH=""

while [ $# -gt 0 ]; do
  case "$1" in
    --selftest) SELFTEST=true; shift ;;
    -h|--help)  sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*)         echo "usage: $0 [--selftest] [path]" >&2; exit 2 ;;
    *)          SCAN_PATH="$1"; shift ;;
  esac
done
[ -n "$SCAN_PATH" ] || SCAN_PATH="$ROOT"
[ -d "$SCAN_PATH" ] || { echo "FATAL: not a directory: $SCAN_PATH" >&2; exit 2; }

FINDINGS=0

# Is $1 itself the top of a git working tree? `[ -d "$1/.git" ]` was false for a linked worktree (its .git is a
# FILE), so the history scan was skipped with an "ok" line and the run passed.
is_checkout() {
  [ "$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" = "$(cd "$1" 2>/dev/null && pwd -P)" ]
}

# One definition of 'a path inside somebody's home directory', used by every scan, mask and name check.
# Linux /home, macOS /Users, /root, and a Windows drive path; a username may start with a capital or a digit.
HOME_RE='((/home|/Users)/[A-Za-z0-9][A-Za-z0-9_.-]*/|/root/|[A-Za-z]:\\Users\\[A-Za-z0-9][A-Za-z0-9_. -]*\\)'   # cofa:sanitise-allow

# ------------------------------------------------------------------ redaction at the printer
# A published CI log is public, so a finding must not contain the string that made it a finding.
# redact2/redact3 handle grep's own output; mask_private is the second line of defence and runs on
# EVERY line hit()/note() print. Two things leak without it and both are load-bearing:
#   * the rule LABEL is built from the pattern, and an operator denylist entry IS the private
#     string — so `identity:zqprivate…` published the string the check refused to publish;
#   * NAME findings (file, directory, branch, symlink target) print the name itself, which is the
#     finding — mask by default, and the reader still has the path shape to act on.
# Masking by SHAPE as well as by denylist entry matters: a home path or a mail address is private
# because of its shape, and it need not be in the denylist to be published by a name finding.
MASKS=()
if [ -f "$DENYLIST" ]; then
  while IFS= read -r _p; do
    case "$_p" in ''|'#'*) continue ;; esac
    MASKS+=("$_p")
  done < "$DENYLIST"
fi
MASK_SHAPES=("$HOME_RE"                                        # cofa:sanitise-allow
             '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}')                 # cofa:sanitise-allow

masked() { local m="$1"; printf '%s…(%d chars)' "${m:0:2}" "${#m}"; }

# A rule label is built from its pattern, and an operator denylist entry IS a private string — so a
# label that quotes the pattern publishes it (the external reviewer's redaction probe caught the gate
# printing an operator entry inside its own FAIL label). Denylist entries get the masked form; the
# shipped classes (public regexes, and the only ones a fresh clone has) keep their readable prefix.
label_for() {
  local p="$1" q
  for q in ${MASKS+"${MASKS[@]}"}; do
    [ "$p" = "$q" ] && { masked "$p"; return; }
  done
  printf '%s' "${p:0:20}"
}

# Any text a finding prints goes through here: mask every denylist match (by MATCH, not by pattern —
# a pattern may be a regex, and what must not be published is the text it matched), then the private
# SHAPES. Printing at the source is not enough: names, refs and symlink targets are themselves the
# finding, so masking at the printer is what makes redaction total rather than per-call-site.
mask_private() {
  local s="$1" p re m i
  for p in ${MASKS+"${MASKS[@]}"}; do
    [ -n "$p" ] || continue
    s="${s//"$p"/"$(masked "$p")"}"
    i=0
    while [ "$i" -lt 8 ]; do
      m="$(printf '%s' "$s" | grep -oE -- "$p" 2>/dev/null | head -1 || true)"
      [ -n "$m" ] || break
      s="${s//"$m"/"$(masked "$m")"}"
      i=$((i + 1))
    done
  done
  for re in "${MASK_SHAPES[@]}"; do
    i=0
    while :; do
      m="$(printf '%s' "$s" | grep -oE -- "$re" 2>/dev/null | head -1 || true)"
      [ -n "$m" ] || break
      s="${s//"$m"/"$(masked "$m")"}"
      i=$((i + 1))
      [ "$i" -ge 8 ] && break
    done
  done
  printf '%s' "$s"
}

hit()  { printf '  FAIL  %-24s %s\n' "$(mask_private "$1")" "$(mask_private "$2")"; FINDINGS=$((FINDINGS + 1)); }
note() { printf '  ok    %-24s %s\n' "$(mask_private "$1")" "$(mask_private "$2")"; }

# Occurrence identity for allowed hits: a short digest of the MATCHED LINE, printed beside the label and
# location. Printing the matched text is exactly what the redaction below exists to prevent, so it cannot
# be the identity. Printing nothing made the allow-marker control blind: its key was label+path only, so a
# SECOND marked hit in an already-approved path produced no new key, the set difference stayed empty, and
# both the gate (rc 0) and the control (rc 0) waved a marked secret through (external review 2026-10-14,
# finding COFA-SAN-001, reproduced on this tree). The digest carries occurrence identity without carrying
# the value, and it changes when the line changes — so an approved occurrence cannot be quietly swapped.
digest12() {
  if   command -v sha256sum >/dev/null 2>&1; then printf '%s' "$1" | sha256sum      | cut -c1-12
  elif command -v shasum    >/dev/null 2>&1; then printf '%s' "$1" | shasum -a 256  | cut -c1-12
  else printf '%s' "$1" | cksum | cut -c1-12; fi   # portable last resort; still varies with the line
}

# Occurrence identity must also be ENVIRONMENT-INDEPENDENT, or the control reports phantom NEW/STALE pairs for
# markers nobody touched. `grep -nIH` echoes the path it was handed, so a local run hashed its own checkout root
# while CI hashed the runner's; and `git grep` prefixes the
# REVISION, which during a pre-push scan is a temporary ref carrying the hook's PID. Both sat inside the digest,
# so the same marker hashed differently on every host and every run (CI run 38528417339 on f75c75b: identical
# marker+path, different hash, gate itself clean). Hash the normalised occurrence instead — repo-relative path,
# no revision — which is exactly what gets printed, and what the control's documented key was always meant to be.
norm_tree() { local l="$1"; printf '%s' "${l#"${SCAN_ROOT:-}"/}"; }
norm_hist() { printf '%s' "$1" | cut -d: -f2-; }

# Redact the matched VALUE before it reaches a log. A gate that prints the secret it found writes
# that secret into every CI log it fails in — the finding a human needs is the file and the line,
# not the value. grep -n prints "path:line:content"; git grep against revisions prints
# "rev:path:line:content". Keeping the first 2 (tree) or 3 (history) colon fields keeps the location
# and drops the value. (Found by the external review: "print the file, line and rule class only".)
redact2() { local l="$1"; l="${l#"${SCAN_ROOT:-}"/}"; printf '%s' "$l" | cut -d: -f1-2; }   # tree hit: file:line, RELATIVE to the scan root
redact3() { printf '%s' "$1" | cut -d: -f1-3; }   # history hit: rev:file:line

# Collect files once. Only two things are skipped, each for a reason:
#   .git/          — its objects are read as HISTORY (git grep), not as files
#   denylist.local — the operator overlay holds the very strings we search for
# Everything else is scanned, including backups, caches and vendored trees. An exclusion by NAME
# is a silent hole: a secret in notes.bak, old.orig, node_modules/ or __pycache__/ is published
# exactly like any other file, and the name is what made it invisible (matrix plant P3).
collect_files() {
  find "$1" -type f \
    -not -path '*/.git/*' -not -name '.git' -not -name 'denylist.local' | sort
}

# Scan one regex across $FILES. here-string (not a pipe) keeps the counter in THIS shell —
# piping into the loop would run it in a subshell and silently swallow every finding.
scan_re() {
  local label="$1" re="$2" out line allowed
  # A line may declare itself legitimate with the allow-marker. Allowed lines are PRINTED, never
  # silently dropped: a marker that hides its own hits is how a real secret gets laundered past a
  # reviewer, so every allowed hit is visible and countable (matrix plant N12).
  allowed="$(grep -nIEH -- "$re" "${FILES[@]}" 2>/dev/null | grep -F "$ALLOW" || true)"
  if [ -n "$allowed" ]; then
    while IFS= read -r line; do note "allowed:$label" "$(redact2 "$line") $(digest12 "$(norm_tree "$line")")"; done <<< "$allowed"
  fi
  out="$(grep -nIEH -- "$re" "${FILES[@]}" 2>/dev/null | grep -vF "$ALLOW" || true)"
  if [ -z "$out" ]; then
    note "$label" "clean"
    return
  fi
  while IFS= read -r line; do hit "$label" "$(redact2 "$line")"; done <<< "$out"
}

# Scan the git HISTORY, not just the working tree. What a clone receives is every object
# reachable from a ref: a file that was committed and then deleted is still fetchable, so a
# spotless tree can publish a leak. Credential classes only — those are unambiguous in history.
scan_history() {
  local dir="$1" revs pat out line
  if ! is_checkout "$dir"; then
    # A tree that is not a checkout has no history to scan: fine for a throwaway selftest tree, never fine for a
    # release check. COFA_REQUIRE_HISTORY=1 (set it in verify-all and CI) turns "not scanned" into a FAILURE.
    if [ "${COFA_REQUIRE_HISTORY:-0}" = "1" ]; then
      hit "history-not-scanned" "$dir is not a git working tree and COFA_REQUIRE_HISTORY=1 — a bare repo or a copy has no history to scan here"
    else
      note "git-history" "not a git checkout — history not scanned"
    fi
    return
  fi
  # A shallow clone sees only its window: a leak older than the window is invisible, and a green result would be false.
  if [ -f "$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null)/shallow" ]; then
    hit "shallow-history" "history is truncated (shallow clone): a leak outside the window is invisible — run: git fetch --unshallow"
  fi
  # ALL commits — not the newest 200. A secret 260 commits back is still in every clone, and the
  # cap made that a silent blind spot (matrix plant P5). Batched with xargs: a long history must
  # not blow the argument limit.
  revs="$(cd "$dir" && git rev-list --all 2>/dev/null | tr '\n' ' ')"
  if [ -z "$revs" ]; then
    note "git-history" "no commits — nothing published yet"
    return
  fi
  local -a pats=()
  if [ -f "$DENYLIST" ]; then
    while IFS= read -r pat; do
      case "$pat" in ''|'#'*) continue ;; esac
      pats+=("$pat")
    done < "$DENYLIST"
  fi
  # Credential classes AND the topology classes the tree scan already knows. History was only
  # looking for credentials, so a tailscale IP, a private IP, an absolute home path or a mail
  # address committed once and deleted was published unexamined (matrix plant P7).
  pats+=('AKIA[0-9A-Z]{16}'                 # cofa:sanitise-allow
         'sk-[A-Za-z0-9_-]{20,}'            # cofa:sanitise-allow
         'gh[pousr]_[A-Za-z0-9]{20,}'       # cofa:sanitise-allow
         'GOCSPX-[A-Za-z0-9_-]{10,}'        # cofa:sanitise-allow
         'xox[baprs]-[A-Za-z0-9-]{10,}'     # cofa:sanitise-allow
         'BEGIN [A-Z ]*PRIVATE KEY'         # cofa:sanitise-allow
         '[0-9]{8,12}:AA[A-Za-z0-9_-]{30,}' # cofa:sanitise-allow
         '100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}'  # cofa:sanitise-allow
         '\b(10\.[0-9]{1,3}|192\.168\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]{1,3}'  # cofa:sanitise-allow
         "$HOME_RE"         # cofa:sanitise-allow
         '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}')  # cofa:sanitise-allow
  for pat in "${pats[@]}"; do
    # -n (line numbers), -a (search BINARY blobs), -E (ERE). The -a is load-bearing twice over:
    # GNU grep 3.5+ writes "binary file matches" to STDERR and puts nothing on stdout, so a hit
    # inside a blob VANISHES without it — and the allow-marker filter needs -a too, or it swallows
    # the finding on the way through. The external reviewer hit exactly this while testing.
    raw="$(printf '%s\n' $revs | xargs -n 100 git -C "$dir" grep -naE -- "$pat" 2>/dev/null || true)"
    # Allowed hits in HISTORY are PRINTED, exactly like the tree scan's: a marker that is honoured silently in the
    # published objects is a marker that can launder a secret nobody will ever see again (matrix plant H3).
    allowed_h="$(printf '%s\n' "$raw" | grep -aF "$ALLOW" || true)"
    if [ -n "$allowed_h" ]; then
      while IFS= read -r line; do note "allowed-history:$(label_for "$pat")" "$(redact3 "$line") $(digest12 "$(norm_hist "$line")")"; done <<< "$allowed_h"
    fi
    out="$(printf '%s\n' "$raw" | grep -avF "$ALLOW" | head -5 || true)"
    if [ -z "$out" ]; then
      note "history:$(label_for "$pat")" "clean"
    else
      while IFS= read -r line; do hit "history:$(label_for "$pat")" "$(redact3 "$line")"; done <<< "$out"
    fi
  done

  # A PARTIAL (blobless) clone whose promisor remote is unreachable lacks objects this scan needs. `git grep` skips
  # them silently, so an incomplete history reads "clean". Checked AFTER the scan on purpose: when the remote IS
  # reachable, git grep has lazily fetched what it needed and nothing is missing; only objects that truly could not
  # be read are left, and those were not scanned.
  local missing
  missing="$(git -C "$dir" rev-list --objects --missing=print --all 2>/dev/null | grep -c '^?' || true)"
  if [ "${missing:-0}" -gt 0 ]; then
    hit "history-incomplete" "$missing object(s) referenced by history are missing locally (partial clone, remote unreachable) and were NOT scanned — fetch them, or scan a full clone"
  fi

  # Messages and tag bodies are published text as well. `git log --format=%B` and annotated tag
  # bodies reach every clone, and neither is a blob the loop above ever sees (plants N4/N5).
  local msgs mclean=true
  # Each entry is prefixed with the object that carries it — a commit hash or a tag ref — so a
  # finding can name WHERE without reprinting the matched text into a public CI log.
  # Every line of a multi-line message gets the carrier prefix (awk), so the first field of ANY matched
  # line is the commit or tag ref, never message text. `cut -f1` on a body line used to print the body.
  msgs="$( { git -C "$dir" log --all --format='%x01%h%n%B' 2>/dev/null; \
             git -C "$dir" for-each-ref --format='%01%(refname)%0a%(contents)' refs/tags 2>/dev/null; } \
           | awk 'index($0, "\001") == 1 { h = substr($0, 2); next } { print h " " $0 }' )"
  if [ -z "$msgs" ]; then
    note "history-messages" "no messages"
  else
    for pat in "${pats[@]}"; do
      out="$(printf '%s\n' "$msgs" | grep -aE -- "$pat" | grep -avF "$ALLOW" | head -5 || true)"
      if [ -n "$out" ]; then
        mclean=false
        while IFS= read -r line; do hit "history-message:$(label_for "$pat")" "$(printf '%s' "$line" | cut -d' ' -f1) — matched text withheld"; done <<< "$out"
      fi
    done
    $mclean && note "history-messages" "clean"
  fi

  # 8b. Commit IDENTITY is published too. `git log` shows %an/%ae/%cn/%ce to every cloner, so a
  # spotless tree can still ship an internal hostname or a third party's address in the one field
  # nobody scans for. Checked against the operator denylist plus one shipped class: a mail address
  # on a non-public domain (.local/.internal/.lan/.corp) is never safe to publish.
  local ids idpats idclean
  ids="$(cd "$dir" && git log --all --format='%h %an <%ae> %cn <%ce>' 2>/dev/null | sort -u)"
  if [ -z "$ids" ]; then
    note "identity" "no commits — nothing published yet"
  else
    # Identity fields legitimately CONTAIN addresses — that is what they are — so this check uses
    # the operator denylist plus ONE shipped class (mail on a non-public domain) and NOT the
    # general address class used for blobs and messages. Reusing the blob classes here flagged
    # every commit in a clean tree; the matrix's C0 control is what surfaced it.
    idpats=()
    if [ -f "$DENYLIST" ]; then
      while IFS= read -r pat; do
        case "$pat" in ''|'#'*) continue ;; esac
        idpats+=("$pat")
      done < "$DENYLIST"
    fi
    idpats+=('@[A-Za-z0-9._-]+\.(local|internal|lan|corp)\b')  # cofa:sanitise-allow
    idclean=true
    for pat in "${idpats[@]}"; do
      out="$(printf '%s\n' "$ids" | grep -Ei -- "$pat" | grep -vF "$ALLOW" | head -5 || true)"
      if [ -n "$out" ]; then
        idclean=false
        while IFS= read -r line; do hit "identity:$(label_for "$pat")" "commit $(printf '%s' "$line" | cut -d' ' -f1) — identity value withheld"; done <<< "$out"
      fi
    done
    $idclean && note "identity" "clean"
  fi
}

run_gate() {
  local dir="$1"
  SCAN_ROOT="$dir"             # every printed locator is relative to this: the same finding must read the same on every machine
  FINDINGS=0                    # each run is self-contained — a stale count would fake a finding
  # `mapfile` is bash 4+; macOS still ships bash 3.2, so a Mac user cloning this repo would hit
  # "mapfile: command not found" and the gate would die before scanning anything. This loop is the
  # portable equivalent: `done < <(...)` keeps it in the current shell, so FILES survives.
  FILES=()
  while IFS= read -r _f; do
    if [ -n "$_f" ]; then FILES+=("$_f"); fi
  done < <(collect_files "$dir")
  if [ "${#FILES[@]}" -eq 0 ]; then
    echo "FATAL: no files to scan under $dir" >&2
    return 2
  fi
  echo "scan: ${#FILES[@]} files under $dir"
  echo

  # ---- 1. operator denylist: the only place real strings may live -------
  if [ -f "$DENYLIST" ]; then
    while IFS= read -r pat; do
      case "$pat" in ''|'#'*) continue ;; esac
      scan_re "denylist:$(label_for "$pat")" "$pat"
    done < "$DENYLIST"
  else
    # A fresh clone must be able to pass: the denylist is a LOCAL overlay (your own names, hosts
    # and peer ids), not part of the publishable guard. The pattern classes below are the guard,
    # and they still run. Warn loudly so the gap is never invisible.
    printf '  WARN  %-24s %s\n' "denylist-missing" "checks/denylist.local absent — operator-specific strings are NOT checked"
    echo "        cp checks/denylist.example checks/denylist.local and fill it in for your deployment."
  fi

  # ---- 1b. forbidden file types: an archive is a leak CONTAINER -----------
  # A zip/tarball of the checkout embeds .git/ and any local-only file (checks/denylist.local),
  # so every pattern below would look straight through it. One landed in this tree during the
  # first-shot install test and had to be deleted by hand — hence a hard rule rather than a note.
  # Process substitution, not `find | while`: the counter must stay in this shell.
  while IFS= read -r archive; do
    hit "archive-in-tree" "${archive#"$1"/} — an archive can embed .git/ and local-only files; it is never source"
  done < <(find "$1" -type f \( -name '*.zip' -o -name '*.tar' -o -name '*.tar.gz' \
    -o -name '*.tgz' -o -name '*.7z' -o -name '*.rar' \) 2>/dev/null)

  # 1b-ii. By CONTENT, not by name: an extension list is defeated by `git archive -o data.bin`.
  # One 512-byte read per file, matching container magics (and tar's 'ustar' at byte 257).
  # A release gate may spend a read per file; this is not a daemon.
  while IFS= read -r f; do
    hex="$(head -c 512 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    [ -z "$hex" ] && continue
    case "$hex" in
      504b0304*|504b0506*|504b0708*) hit "archive-in-tree" "${f#"$1"/} — ZIP container (magic bytes); renaming it does not make it source" ;;
      1f8b08*)                       hit "archive-in-tree" "${f#"$1"/} — gzip container (magic bytes); renaming it does not make it source" ;;
      425a68*)                       hit "archive-in-tree" "${f#"$1"/} — bzip2 container (magic bytes); renaming it does not make it source" ;;
      377abcaf*)                     hit "archive-in-tree" "${f#"$1"/} — 7z container (magic bytes); renaming it does not make it source" ;;
      526172211a07*)                 hit "archive-in-tree" "${f#"$1"/} — RAR container (magic bytes); renaming it does not make it source" ;;
    esac
    [ "${hex:514:10}" = "7573746172" ] && hit "archive-in-tree" "${f#"$1"/} — tar container (ustar magic at byte 257)"
    continue
  done < <(find "$1" -type f ! -path '*/.git/*' ! -name '.git' 2>/dev/null)

  # 1b-iii. A nested .git is a SECOND history: its objects are invisible to the history scan
  # below, and the pattern scans above read its internals as opaque bytes. Refuse it outright.
  while IFS= read -r g; do
    hit "nested-git-dir" "${g#"$1"/} — a nested .git is a second history this scan cannot read"
  done < <(find "$1" -mindepth 2 -type d -name .git 2>/dev/null)

  # 1b-iv. A non-empty BINARY is refused by RULE — not by extension, not by a magic-byte list.
  # Every pattern scan in this file uses grep -I, which SKIPS binary files silently. So a secret
  # inside a zlib stream, a sqlite database, a NUL-padded file, a UTF-16LE export, a git bundle
  # or a scrubbed copy of .git/objects passes every scan below with no match at all. Those are
  # one class, not six (matrix plants P1/P2/P6/P8b/N8/N9/N10). The property that matters is
  # "can grep read this as text". A deliberate binary must be named in checks/binary-allowlist
  # (one repo-relative path per line) — declared, and reported as declared, never silent.
  local binal="" rel
  [ -f "$ROOT/checks/binary-allowlist" ] && binal="$ROOT/checks/binary-allowlist"
  while IFS= read -r f; do
    [ -s "$f" ] || continue
    LC_ALL=C grep -qI . "$f" 2>/dev/null && continue     # readable as text → covered below
    [ "$(LC_ALL=C tr -d '[:space:]' < "$f" 2>/dev/null | wc -c)" -eq 0 ] && continue  # blank text
    rel="${f#"$1"/}"
    if [ -n "$binal" ] && grep -qxF -- "$rel" "$binal" 2>/dev/null; then
      note "binary-allowlisted" "$rel (declared deliberate)"
      continue
    fi
    hit "binary-in-tree" "$rel — binary is never pattern-scanned (grep -I skips it); allowlist only if deliberate"
  done < <(find "$1" -type f ! -path '*/.git/*' ! -name '.git' 2>/dev/null)

  # 1c. NAMES are published too — a content scan never sees a path. A denylist string inside a
  # file name, a directory name or a branch name rides into every clone with nothing matching
  # (plants N2/N3/N6). Symlink TARGETS are the same class: a link is a name pointing somewhere,
  # and `find -type f` skips links entirely (plant N1).
  local -a namepats=()
  if [ -f "$DENYLIST" ]; then
    while IFS= read -r pat; do
      case "$pat" in ''|'#'*) continue ;; esac
      namepats+=("$pat")
    done < "$DENYLIST"
  fi
  namepats+=("$HOME_RE" '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}')  # cofa:sanitise-allow

  name_scan() {                # name_scan <label> <newline-separated names>
    local label="$1" list="$2" npat nout nline
    [ -n "$list" ] || return 0
    for npat in "${namepats[@]}"; do
      nout="$(printf '%s\n' "$list" | grep -iE -- "$npat" || true)"
      [ -n "$nout" ] || continue
      while IFS= read -r nline; do hit "$label" "$nline — the NAME is published; rename it"; done <<< "$nout"
    done
  }

  name_scan "name-in-path" "$(find "$1" -mindepth 1 -not -path "$1/.git" -not -path "$1/.git/*" 2>/dev/null | sed "s|^$1/||")"
  if is_checkout "$1"; then
    name_scan "name-in-ref" "$(git -C "$1" for-each-ref --format='%(refname)' 2>/dev/null)"
  fi
  while IFS= read -r l; do
    local tgt
    tgt="$(readlink "$l" 2>/dev/null || true)"
    [ -n "$tgt" ] || continue
    local lrel="${l#"$1"/}"
    case "$tgt" in
      /*) hit "symlink-absolute" "$lrel → $tgt — absolute target; a published link must stay inside the tree" ;;
      *)  # relative: resolve the target's directory and require it to stay under the tree root
          local tdir root_real
          root_real="$(cd "$1" && pwd -P)"
          tdir="$(cd "$(dirname "$l")" 2>/dev/null && cd "$(dirname "$tgt")" 2>/dev/null && pwd -P)"
          case "$tdir" in
            "$root_real"|"$root_real"/*) ;;
            *) hit "symlink-escapes" "$lrel → $tgt — resolves outside the tree (or dangles); a published link must stay inside" ;;
          esac ;;
    esac
    name_scan "symlink-target" "$lrel → $tgt"
  done < <(find "$1" -type l ! -path '*/.git/*' 2>/dev/null)

  # ---- 2. credential material ------------------------------------------
  scan_re "aws-key"        'AKIA[0-9A-Z]{16}'                                                    # cofa:sanitise-allow
  scan_re "openai-key"     'sk-[A-Za-z0-9_-]{20,}'                                               # cofa:sanitise-allow
  scan_re "github-pat"     'gh[pousr]_[A-Za-z0-9]{20,}'                                          # cofa:sanitise-allow
  scan_re "google-oauth"   'GOCSPX-[A-Za-z0-9_-]{10,}'                                           # cofa:sanitise-allow
  scan_re "slack-token"    'xox[baprs]-[A-Za-z0-9-]{10,}'                                        # cofa:sanitise-allow
  scan_re "chatbot-token" '[0-9]{8,12}:AA[A-Za-z0-9_-]{30,}'                                    # cofa:sanitise-allow
  scan_re "private-key"    'BEGIN [A-Z ]*PRIVATE KEY'                                            # cofa:sanitise-allow
  scan_re "bearer-literal" '(Bearer|token=)[[:space:]]*[A-Za-z0-9._-]{24,}'                      # cofa:sanitise-allow
  scan_re "hex-secret"     '[^0-9A-Fa-f][0-9A-Fa-f]{40,}[^0-9A-Fa-f]'                            # cofa:sanitise-allow

  # ---- 3. addressing / topology ----------------------------------------
  scan_re "tailscale-ip"   '100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}' # cofa:sanitise-allow
  scan_re "private-ip"     '\b(10\.[0-9]{1,3}|192\.168\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]{1,3}' # cofa:sanitise-allow
  scan_re "abs-home-path"  "$HOME_RE"                                            # cofa:sanitise-allow
  scan_re "email-address"  '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'                      # cofa:sanitise-allow

  # ---- 4. populated peer/config blocks (roster stays placeholder-only) --
  if [ -f "$dir/a2a-mesh/config.sample.yaml" ]; then
    local bad
    bad="$(sed -nE 's/^[[:space:]]{2}([A-Za-z0-9_-]+):[[:space:]]*$/\1/p' "$dir/a2a-mesh/config.sample.yaml" \
          | grep -viE '^(peers|peer_[a-z][a-z0-9_]*)$' || true)"
    if [ -n "$bad" ]; then
      local kn=0
      while IFS= read -r k; do
        kn=$((kn + 1))
        [ -n "$k" ] && hit "peer-key-placeholder" "config.sample.yaml: non-placeholder peer key #$kn, value withheld (use peer_a/peer_b/...)"
      done <<< "$bad"
    else
      note "peer-key-placeholder" "clean"
    fi
  fi

  # ---- 5. private skill / internal harness names -----------------------
  # Deliberately NOT listed here: naming a private skill in this file would itself be the leak
  # the gate exists to catch. Those literals live in checks/denylist.local (git-ignored); the
  # check below proves the denylist is actually covering them.

  # ---- 6. opaque blobs --------------------------------------------------
  scan_re "b64-blob"       '[A-Za-z0-9+/]{60,}={0,2}'                                            # cofa:sanitise-allow

  # ---- 7. executable bits (permissions ride the git index; a 664 checkout → exit 126) ----
  local f
  while IFS= read -r f; do
    [ -x "$f" ] || hit "exec-bit" "${f#"$dir"/} is not executable (chmod +x)"
  done < <(find "$dir" -name '*.sh' -type f -not -path '*/.git/*' | sort)

  # ---- 8. published history ---------------------------------------------
  if is_checkout "$dir"; then
    # every path that ever existed (a file renamed before publish keeps its old name in history)
    name_scan "name-in-history" "$(git -C "$dir" log --all --name-only --format= 2>/dev/null | sort -u)"
    # every symlink target that ever existed: `git grep` does not search link blobs, so read them
    name_scan "symlink-in-history" "$(git -C "$dir" log --all --raw --no-abbrev --format= 2>/dev/null \
        | awk '$2 == "120000" {print $4}' | sort -u \
        | while read -r b; do git -C "$dir" cat-file -p "$b" 2>/dev/null; echo; done)"
  fi
  scan_history "$dir"

  echo
  if [ "$FINDINGS" -ne 0 ]; then
    echo "sanitise: FAILED — $FINDINGS finding(s). Do NOT push; fix or allowlist each line."
    return 1
  fi
  echo "sanitise: PASSED — no findings."
  return 0
}

# ---- self-test: the gate must be able to fail, and must not cry wolf ----
if $SELFTEST; then
  # The selftest scans throwaway trees that are not git checkouts BY DESIGN. COFA_REQUIRE_HISTORY=1 is for the
  # real tree scan; left exported it would fail the selftest's own "a clean tree must pass" check.
  export COFA_REQUIRE_HISTORY=0
  TREE="$(mktemp -d)"
  LOGS="$(mktemp -d)"          # logs live OUTSIDE the scanned tree, else the gate reads its own output
  trap 'rm -rf "$TREE" "$LOGS"' EXIT
  # Assembled at runtime so this file never contains a scannable literal itself.
  printf 'api_key = %s%s\n' 'sk-' 'ABCDEF0123456789abcdef0123456789' > "$TREE/planted_leak.txt"
  printf 'endpoint = <host>:<port>\nkey = <YOUR_API_KEY>\n' > "$TREE/clean_placeholder.txt"

  echo "=== selftest: planted canary must be caught ==="
  run_gate "$TREE" > "$LOGS/dirty.log" 2>&1; dirty_rc=$?
  if [ "$dirty_rc" -eq 1 ]; then
    echo "  ok    canary caught (exit 1)"; grep -m2 'openai-key' "$LOGS/dirty.log" | sed 's/^/        /'
  else
    echo "  FAIL  scanner did NOT fail on a planted secret (exit $dirty_rc) — gate is vacuous"
    FINDINGS=$((FINDINGS + 1))
  fi

  echo
  echo "=== selftest: a clean tree must pass (no false alarm) ==="
  rm -f "$TREE/planted_leak.txt"
  run_gate "$TREE" > "$LOGS/clean.log" 2>&1; clean_rc=$?
  if [ "$clean_rc" -eq 0 ]; then
    echo "  ok    clean tree passes (exit 0)"
  else
    echo "  FAIL  clean placeholder tree reported findings (exit $clean_rc)"; grep 'FAIL' "$LOGS/clean.log" | sed 's/^/        /'
    FINDINGS=$((FINDINGS + 1))
  fi

  echo
  echo "=== selftest: an archive is caught by CONTENT, and a nested .git is refused ==="
  printf 'PK\003\004' > "$TREE/data.bin"     # a zip renamed so no extension rule can see it
  mkdir -p "$TREE/deep/.git"                 # a second history the scan cannot read
  before=$FINDINGS
  run_gate "$TREE" > "$LOGS/magic.log" 2>&1; magic_rc=$?
  FINDINGS=$before          # run_gate counts within its own run; keep this run's hits out of the tally
  if [ "$magic_rc" -eq 1 ] && grep -q 'data.bin' "$LOGS/magic.log" && grep -q 'nested-git-dir' "$LOGS/magic.log"; then
    echo "  ok    renamed zip caught by magic bytes; nested .git refused"
    grep -m2 'FAIL' "$LOGS/magic.log" | sed 's/^/        /'
  else
    echo "  FAIL  content-based archive rule missed a renamed zip or a nested .git (exit $magic_rc)"
    FINDINGS=$((FINDINGS + 1))
  fi
  rm -f "$TREE/data.bin"; rm -rf "$TREE/deep"

  echo
  echo "=== selftest: a secret committed then deleted must STILL be caught (history) ==="
  if command -v git >/dev/null 2>&1; then
    HIST="$(mktemp -d)"
    ( cd "$HIST" && git init -q && git config user.email selftest.invalid \
      && git config user.name selftest \
      && printf 'api_key = %s%s\n' 'sk-' 'ABCDEF0123456789abcdef0123456789' > leaked_then_removed.txt \
      && printf 'placeholder = <YOUR_API_KEY>\n' > keep.txt \
      && git add -A && git commit -qm add \
      && rm leaked_then_removed.txt && git commit -qam remove ) >/dev/null 2>&1
    before=$FINDINGS
    run_gate "$HIST" > "$LOGS/history.log" 2>&1; hist_rc=$?
    FINDINGS=$before          # run_gate counts within its own run; keep this run's hits out of the tally
    rm -rf "$HIST"
    if [ "$hist_rc" -eq 1 ] && grep -q 'history:sk-' "$LOGS/history.log"; then
      echo "  ok    history scan caught the deleted-but-still-published secret"
      grep -m2 'FAIL  history' "$LOGS/history.log" | sed 's/^/        /'
    else
      echo "  FAIL  history scan missed a secret still present in the published objects (exit $hist_rc)"
      FINDINGS=$((FINDINGS + 1))
    fi
  else
    echo "  ok    git unavailable — history selftest skipped"
  fi

  echo
  if [ "$FINDINGS" -eq 0 ]; then
    echo "selftest: PASSED — the gate can fail, and does not cry wolf."
    exit 0
  fi
  echo "selftest: FAILED — see above."
  exit 1
fi

run_gate "$SCAN_PATH"
