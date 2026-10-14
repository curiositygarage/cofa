# Sanitisation Rules

This file defines what must never enter the COFA repository. Every contributor should run through this checklist mentally before pushing changes. This repo becomes public.

## The rules

### 1. No real secrets

- **API keys, tokens, passwords, certificates**: Never include real credential values. Use `<YOUR_API_KEY>`, `<PASSWORD>`, etc.
- **Expired keys are still forbidden**. Anyone can generate expired keys for testing — use placeholders instead.

### 2. No private infrastructure details

- **Real hostnames, IP addresses, ports**: Replace with `<host>`, `<port>`, `127.0.0.1` as appropriate.
- **Machine names, server identifiers**: Remove or generalise. Write for a competent stranger who has never met anyone involved.
- **Internal network topology**: Describe generically. If an example needs a network diagram, use fictional IPs (documentation blocks: `192.0.2.0/24`) and explain they are illustrative. <!-- cofa:sanitise-allow -->

### 3. No personal or private project references

- **Individual names**: No personal names anywhere, including authorship lines. Use generic terms like "contributor", "operator", "user".
- **Family/private project names**: Do not reference any private system, employer, or individual.
- **Bot usernames and chat-platform user IDs**: These are operational identifiers tied to specific deployments. Do not include them in repo files.

### 4. No agent-specific wiring

- **Peer registry contents**: A file that maps agents to endpoints is deployment-specific. Document its format but never commit a populated one.
- **Checkpoint files**: Generated state files (`LAST_TASK.md`, session logs, etc.) contain transient work data. Do not commit these.

### 5. Check before you push — one gate, not a checklist

There is exactly **one** gate, and it is a script, not a set of commands to remember:

```bash
bin/scan-sanitisation.sh            # scan the repo root: exit 0 clean, exit 1 findings
bin/scan-sanitisation.sh --selftest # prove the gate can fail and does not cry wolf
```

It scans every file for credential shapes, private addressing, operator strings from
`checks/denylist.local` (git-ignored), opaque blobs, populated peer rosters and missing
executable bits. A finding exits non-zero and prints `file:line` and the rule class — never the
matched value, so a failing run is safe to paste into a public CI log. A line that must legitimately
mention a forbidden pattern carries the marker `cofa:sanitise-allow`.

`checks/gate-plant-matrix-v4.sh bin/scan-sanitisation.sh` is the regression test for the gate
itself: each leak shape is planted in a throwaway repository and required to make the gate exit
non-zero. Quote its own `plants run:` line rather than a number written here — the count moved
41 → 44 with the round-10 shapes, and a doc copy of it is what goes stale. (v3 covers the pattern
classes; W1–W3 were added with the round-10 fix, so the
worktree `.git` pointer file stays fixed: W1 requires the pointer file *not* to alarm, W2 requires
the exclusion not to blind the gate to a leak planted beside it, and W3 requires the exclusion not
to extend to a symlink named `.git`.)
`checks/gate-redaction-probe-v2.sh bin/scan-sanitisation.sh` is the same idea for the other half of
the contract — each shape is required to make the gate fail *and* keep the matched
value out of its output. Its own `probes run:` line carries the count (20 at round 21), not this
file. `checks/gate-history-state-probe.sh bin/scan-sanitisation.sh` covers the
third thing a gate can get wrong: the history it is actually *reading*. A shallow clone, a linked
worktree (whose `.git` is a file, so `[ -d "$dir/.git" ]` was false and the history scan was skipped
with an "ok" line) and a bare mirror under `COFA_REQUIRE_HISTORY=1` must each make the gate fail
rather than read green. Non-vacuous: three of its four states pass against the gate revision before
the round-5 history patch. `checks/verify-all.sh` runs all three probes, so CI cannot drift from
them.

Do not add a second scanner. Two gates that disagree are worse than one that fails.

**Give it a trigger.** A gate nobody runs is documentation. Wire it into your publish path —
a `pre-push` hook in the clone, a CI step, or a release script — so the scan runs on every push
rather than on good intentions:

```bash
# .git/hooks/pre-push (chmod +x)
#!/bin/sh
exec "$(git rev-parse --show-toplevel)/bin/scan-sanitisation.sh"
```

If the scan produces results, review each line. False positives cost a minute; a true positive
in a public repository cannot be taken back.

## Limits of this gate — what it cannot catch

Written down deliberately: a scanner that implies completeness is more dangerous than one that
states its shape.

- **Unprefixed secrets.** It matches known credential *shapes* (`sk-…`, `AKIA…`, `ghp_…`, PEM
  headers). A bare token with no format — a password in a config file, an opaque 32-char string —
  has no shape to match and needs the operator denylist.
- **Binary and encoded blobs.** Base64 of a secret, or a secret inside a PNG/PDF, reads as opaque
  bytes. The archive rule (1b/1b-ii) refuses archives in the tree outright, which removes the most
  common container — a base64 blob in a `.txt` still passes.
- **Facts split across lines** (a username on one line, its token two lines below).
- **New credential formats.** The pattern list is finite and ages.
- **Semantic leaks** — a person's name, a project codename, a business detail. Shipped patterns
  cover *classes*; operator-specific names live in the **git-ignored** `checks/denylist.local`.
  A fresh clone therefore checks classes only, and the gate warns loudly when that file is absent.
- **Anything outside the scanned path.** The gate scans the tree you point it at, plus (in a git
  repo) the history reachable from its refs. **Unreachable objects are not covered by the standalone
  gate**: they are pushable by object ID and invisible to `git rev-list --all`, so they are refused by
  `checks/verify-all.sh` (release) and by `checks/pre-push.sample` (before a push), both fail-closed.
  The gate cannot see a file you never put there, a sibling directory, or a log outside the tree.
- **History scanning is clone-depth-sensitive.** Run it against a clone with full history
  (`fetch-depth: 0` in CI); a shallow clone narrows the scan silently.
- **Cost:** the magic-byte rule does one 512-byte read per file. Fine for a release gate, not
  designed for a monorepo.
- **The allow-marker in history.** The marker suppresses a hit silently in the *history* scan and in
  commit/tag messages (the tree scan prints every allowed hit, with its location). A marked line
  buried in history is therefore reported only if the marker itself is not the reason it is skipped;
  plant matrix cases H3/H4 keep this visible rather than pretending otherwise.
- **Allow-control scope on a rebuilt lane.** `checks/verify-allowed-hits.sh` compares tree *and* history
  occurrences by default. A lane whose history is regenerated on every publish — a squashed snapshot, where
  every revision is rebuilt from the same tree — cannot hold a stable history baseline: a history
  occurrence's identity depends on the commit that landed it, **including the baseline commit itself**, so
  the comparison churns by construction and never converges. Such a lane commits
  `checks/allow-control.scope` containing `tree`, and the control then compares tree occurrences only.
  This narrows what is **compared**, never what is **scanned**: the gate still scans the full history for
  leaks, and a marker on a private-overlay match still fails. The effective scope is printed on every run
  and recorded in the baseline header, so it can never change silently.
- **Case folding is byte-wise (`LC_ALL=C`).** One locale for every `grep` closed the invalid-UTF-8
  blind spot, at the cost of `-i` no longer case-folding non-ASCII. A denylist entry with an
  accented capital will not match its lower-case spelling; write the variant you expect to see.
- **Sparse checkouts and `git replace`.** The scan reads the object store, not what a working tree
  materialised: a sparse checkout leaves paths absent without the scan noticing it never saw them
  (the tree scan walks the checkout, the history scan walks objects — a sparse path exists in one and
  not the other), and a `git replace` ref makes a commit read as a *different* commit, so history is
  reported as its replacement. Publish from a full, non-sparse clone; if you must use either, treat
  the gate as unrun for the affected range.
- **A masked name is meant to be found, not read.** Findings print `<first two chars>…(<n> chars)`
  instead of the private string, so the log never publishes it. Locate the entry with a glob
  (`git ls-files | grep -i '^<first two chars>'`); the mask is not a lossy report, it is the pointer.
- **What the redaction covers.** Operator denylist entries (matched by the text the pattern matched),
  absolute home paths and mail addresses. A private *shape* the gate has no class for — an internal
  hostname that is in neither the denylist nor a shipped class — is printed as found.

What to do instead of trusting it: keep the operator denylist populated, run the gate against the
*exact* tree you are about to publish, and still read the diff. This is one gate, not a substitute
for review.
