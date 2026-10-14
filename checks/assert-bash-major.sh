#!/bin/sh
# assert-bash-major.sh <bash-binary> <major> — exit 0 only if that binary reports the wanted bash major version.
[ $# -eq 2 ] || { echo "usage: $0 <bash-binary> <major>" >&2; exit 2; }
got="$("$1" -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null)" || { echo "FAIL: cannot run $1" >&2; exit 1; }
[ "$got" = "$2" ] || { echo "FAIL: $1 is bash major '$got', wanted $2" >&2; exit 1; }
echo "ok: $1 is bash $("$1" -c 'echo "$BASH_VERSION"')"
