# Security policy

## Reporting a vulnerability

Use **GitHub private vulnerability reporting** on this repository
(*Security → Report a vulnerability*). Please do not open a public issue or pull request for a
security problem.

There is deliberately **no email address in this file**. A personal address in a public repo gets
harvested, and a reporting channel nobody monitors is worse than none. If private reporting is not
enabled on this repository, treat that as a configuration gap worth opening an issue about — without
naming the vulnerability.

## What counts as a vulnerability here

This project ships a **sanitisation gate** and a **policy engine**, so its own honesty is part of
its attack surface:

- a published artifact (file, commit, or git object) that contains a credential, a secret, PII, or
  an operator-specific identifier;
- a bypass of the gate or of a component filter that lets such material through — for example a
  base64 blob inside a text file, a secret split across two lines, or an operator string that
  survives because the denylist overlay was absent;
- a policy rule that allows an operation its documentation says is denied, or the engine mangling a
  rule string so the rule can never match;
- command execution or credential disclosure through task input in the A2A client.

Out of scope: the documented limits of the pattern scanner (see `SANITISATION.md` → *Limits of this
gate*) are known and stated, not vulnerabilities. A missing pattern for a format nobody has
published yet is a missing pattern.

## The pre-push gate, its audit log, and what it does not cover

`checks/pre-push.sample` is the trigger for the gate. Copied to `.git/hooks/pre-push`, it:

- reads the **ref records git hands a pre-push hook on stdin** (`<local-ref> <local-sha>
  <remote-ref> <remote-sha>`), creates a temporary ref at each pushed object so the gate's history
  scan reaches exactly what is about to be published, exports every pushed snapshot and scans it with
  the full tree rules, and refuses any record it cannot read. A working-tree scan is not a scan of
  what a push would publish, so a manual run (empty stdin) is refused unless
  `COFA_PREPUSH_ALLOW_MANUAL=1`;
- proves the operator overlay and refuses the push if that proof fails;
- runs `bin/scan-sanitisation.sh` **and** `checks/verify-allowed-hits.sh`. A marked hit is *printed*
  but never fails the gate, so printing is not a control — the allow-marker control is what refuses
  one, and in the hook it runs every time (the aggregate verifier is not in a push's path);
- refuses unreachable objects: an unreachable object is pushable by object ID and unscanned by any
  ref-based scan;
- writes **two audit lines per attempt** to `$HOME/.cofa-pre-push-audit.log`:

  - the attempt — commit, gate hash, overlay state, prover verdict, refs scanned; and
  - the gate's own result — `result=ACCEPTED`, `result=REFUSED(...)` or `result=ERROR(rc=2)`, with
    `findings=<count>` and the distinct `rules=` labels. Never a file path, a line number or matched
    text; denylist-derived labels are masked before they reach either the log or the audit file.

  **Every append is verified.** If a record cannot be persisted the push is refused and the reason is
  printed — an unrecorded push is not attributable, and silently continuing would leave the audit log
  looking clean when it is merely absent. An audit destination inside the repository is refused too.

Limits, stated rather than implied:

- **`git push --no-verify` bypasses the hook entirely and writes no audit line.** That is a residual
  risk of any hook-based control, and it is documented rather than fixed. Before any visibility
  change, confirm the tip of `main` has a matching `result=ACCEPTED` line — an absent line is not a
  clean push. CI covers the shipped pattern classes for every push that reaches GitHub; it does
  **not** cover the private overlay (`checks/denylist.local` never leaves the operator's machine).
- **A hook is only as good as its installation.** The control above exists only where
  `checks/pre-push.sample` has been copied into `.git/hooks/pre-push`; a clone without it has the CI
  gate and nothing else. `checks/verify-all.sh` runs the same checks server-side of the decision.
- **A gate that cannot run is not a pass.** An absent overlay makes the prover exit 2, which refuses
  the push, and the audit line records `ERROR(rc=2)` rather than going silent.
- **The audit log is local and unauthenticated.** It is attribution evidence for an honest operator,
  not tamper-proof evidence against a hostile one.

## What this software is not

- **The gate is a pattern scanner, not a sandbox.** It will not *match* an unprefixed secret or one
  split across lines. A secret inside a binary or encoded blob is never matched either: binaries and
  archives are refused wholesale rather than read (so they cannot be published), but a base64 blob
  inside a text file still passes. The complete list is in `SANITISATION.md` → *Limits of this gate*.
- **`policy-cel` is a guardrail for well-meaning automation, not a security boundary.** It constrains
  what an agent asks for; anyone with shell access can bypass it.
- **The A2A client trusts its peers' endpoints.** `--sender` / `metadata.sender` is a self-asserted
  label, not authentication: a peer derives the caller's identity from the connection, never from
  the message.

## Supported versions

Pre-1.0 (`VERSION`). Only the tip of `main` is supported; there are no maintenance branches.
