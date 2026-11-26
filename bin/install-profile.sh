#!/usr/bin/env bash
# Install a COFA profile into a destination directory.
#
# A profile is an install set, not a promise: each copied component still has to pass its own
# checks/verify.sh. The point of the profile is what does NOT get copied. The default is `solo`,
# because a single-agent household must not receive a peer lane - and an agent that never gets
# one never goes looking for peers, siblings or a registry that is not there.
#
# exit 0 installed · 1 bad component / bad dest · 2 usage
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="solo"
DEST=""
DRY=0

usage() {
  cat <<'USAGE'
usage: bin/install-profile.sh [--profile solo|mesh] [--dest DIR] [--dry-run] [--list]

  --profile NAME  profile file under profiles/ (default: solo)
  --dest DIR      destination directory (required unless --list/--dry-run)
  --dry-run       print what would be copied, copy nothing
  --list          print the profiles and their components, copy nothing
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --dest)    DEST="${2:-}"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --list)    DRY=1; DEST=""; LIST=1; shift ;;
    -h|--help) usage; exit 2 ;;
    *) echo "USAGE: unknown arg $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ ! -d "$ROOT/profiles" ]; then
  echo "USAGE: no profiles/ directory at $ROOT" >&2
  exit 2
fi

if [ "${LIST:-0}" = "1" ]; then
  for f in "$ROOT"/profiles/*.txt; do
    name="$(basename "$f" .txt)"
    printf '%s: %s\n' "$name" "$(grep -vE '^[[:space:]]*(#|$)' "$f" | tr '\n' ' ')"
  done
  exit 0
fi

FILE="$ROOT/profiles/$PROFILE.txt"
if [ ! -f "$FILE" ]; then
  echo "USAGE: unknown profile '$PROFILE' (available: $(ls "$ROOT"/profiles/*.txt 2>/dev/null | xargs -n1 basename | sed 's/\.txt$//' | tr '\n' ' '))" >&2
  exit 2
fi

COMPONENTS=()
while IFS= read -r line; do
  [ -n "$line" ] && COMPONENTS+=("$line")
done < <(grep -vE '^[[:space:]]*(#|$)' "$FILE")
if [ "${#COMPONENTS[@]}" -eq 0 ]; then
  echo "USAGE: profile '$PROFILE' lists no components" >&2
  exit 2
fi

rc=0
for c in "${COMPONENTS[@]}"; do
  if [ ! -d "$ROOT/$c" ] || [ ! -f "$ROOT/$c/README.md" ]; then
    echo "MISSING: component '$c' has no directory + README.md at $ROOT/$c" >&2
    rc=1
  fi
done
[ "$rc" -eq 0 ] || exit 1

if [ "$DRY" = "1" ] || [ -z "$DEST" ]; then
  echo "profile: $PROFILE"
  echo "would install (${#COMPONENTS[@]}): ${COMPONENTS[*]}"
  NOT_INSTALLED=()
  for d in "$ROOT"/*/; do
    name="$(basename "$d")"
    case " ${COMPONENTS[*]} " in *" $name "*) ;; *) [ -f "$d/README.md" ] && NOT_INSTALLED+=("$name") ;; esac
  done
  [ "${#NOT_INSTALLED[@]}" -gt 0 ] && echo "not installed: ${NOT_INSTALLED[*]}"
  [ -z "$DEST" ] && { echo "USAGE: --dest is required to install" >&2; exit 2; }
  exit 0
fi

mkdir -p "$DEST" || { echo "USAGE: cannot create $DEST" >&2; exit 1; }

for c in "${COMPONENTS[@]}"; do
  if [ -e "$DEST/$c" ]; then
    echo "EXISTS: $DEST/$c - refusing to overwrite an existing component" >&2
    rc=1
    continue
  fi
  cp -a "$ROOT/$c" "$DEST/$c" || rc=1
  echo "installed: $c"
done
[ "$rc" -eq 0 ] || exit 1

# A machine-readable record of what this tree is, so a later audit does not have to guess
# from directory names. No author, no date, no upstream URL: the tree describes itself.
{
  echo "profile: $PROFILE"
  echo "components:"
  for c in "${COMPONENTS[@]}"; do echo "  - $c"; done
} > "$DEST/PROFILE"

echo "profile $PROFILE -> $DEST (${#COMPONENTS[@]} components; record at $DEST/PROFILE)"
echo "next: run each component's checks/verify.sh inside $DEST"
exit 0
