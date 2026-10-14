#!/usr/bin/env bash
# checks/verify-unreachable.sh — no unreachable object may survive in this repository.
#
# An `--amend` (or a rebase, or a reset) leaves the ORIGINAL commit in the object store. The gate's
# identity rule reads `git log --all`, so it never sees an unreachable commit: an amended commit that
# carried a private identity is invisible to the gate and still travels in every clone, zip and folder
# copy. That is exactly the incident this check guards (external review, round 11). It costs a second
# and passes trivially in CI's fresh clone — a fresh clone has no unreachable objects.
#
#   usage:  checks/verify-unreachable.sh [<repo>]
#   exit   0 = none (clean)   1 = unreachable objects present   3 = usage / not a repo
set -u

REPO="${1:-.}"
cd "$REPO" 2>/dev/null || { echo "no such directory: $REPO" >&2; exit 3; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git repository: $REPO" >&2; exit 3; }

n="$(git fsck --unreachable --no-reflogs 2>/dev/null | grep -c .)"

if [ "$n" -eq 0 ]; then
  echo "unreachable: clean — git fsck --unreachable --no-reflogs reports nothing"
  exit 0
fi

echo "unreachable: $n object(s) still in the object store"
git fsck --unreachable --no-reflogs 2>/dev/null | sed 's/^/  /'
echo "  Ids only — no content is printed, and the gate cannot see these: it reads 'git log --all'."
echo "  An amended commit carrying a private identity ships in every clone and every zip of it."
echo "  purge: git reflog expire --expire=now --all && git gc --prune=now"
exit 1
