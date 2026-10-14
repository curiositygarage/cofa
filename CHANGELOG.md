# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project uses
[semantic versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- `checks/verify-allowed-hits.sh` gains `--tree-only` and the lane-scope marker `checks/allow-control.scope`.
  A lane that rebuilds its history on every publish (the public squashed snapshot) cannot hold a stable
  history baseline — a history occurrence's key depends on the commit that landed it, including the baseline
  commit itself, so the comparison churned and the control never converged. On such a lane the control now
  compares **tree occurrences only**. This narrows the *comparison*, not the *scan*: the gate still scans the
  full history for leaks, and a marker silencing a private-overlay match still fails. A development repo
  carries no marker file, so its scope stays tree + history — unchanged. The effective scope prints on every
  run and is recorded in the baseline header.

### Added
- `checks/verify-all.sh` — the single entry point: gate selftest, gate scan, then the four component
  verifiers. A component that cannot be verified exits 2 and is reported **NOT VERIFIED** rather
  than counted as a pass; `--require-all` makes that fatal (this is what CI runs).
- `.github/workflows/check.yml` — CI across Python 3.9/3.12 × both long-term-memory client paths
  (psycopg2 and the psql fallback) against a PostgreSQL 16 service, with `fetch-depth: 0` so the
  gate's history scan is not silently narrowed.
- `SECURITY.md`, `VERSION`, this changelog, and a *Limits of this gate* section in
  `SANITISATION.md` that states what the pattern scanner cannot catch.
- Archive detection by **content**, not just file name: `bin/scan-sanitisation.sh` now reads the
  first 512 bytes of every file and refuses ZIP/gzip/bzip2/7z/RAR magic (and tar's `ustar` marker),
  so a renamed archive cannot slip through. It also refuses a **nested `.git`**, which is a second
  history the scan cannot read.
- Gate selftest now plants a renamed archive and a nested `.git` and requires both to be caught.
- `checks/gate-plant-matrix-v2.sh` — the gate's own regression test: 33 leak shapes, each planted in
  a throwaway repository, each required to make the gate exit non-zero, run both in a UTF-8 locale
  and under `LC_ALL=C`. `checks/verify-all.sh` runs it as a gate step, so CI cannot drift from it.
- `checks/gate-history-state-probe.sh` — the gate's regression test for the *state of the history it
  is reading*: a shallow clone (`shallow-history`), a linked worktree and a bare mirror under
  `COFA_REQUIRE_HISTORY=1` (`history-not-scanned`) must each make the gate fail, not read green.
  Wired as a `gate_step` in `checks/verify-all.sh`, invoked with `bash` rather than `sh` (it aborts
  on a too-short plant instead of passing). Non-vacuous: three of its four states pass against the
  gate revision before the round-5 history patch — those three behaviours were unguarded, not
  unverified.
- `checks/assert-bash-major.sh` — asserts that a bash binary reports a given major version, the only
  portable way to say "this job really ran the shell we claim". The Linux job proves the check can
  FAIL (its bash is major 5, so asking for 3 must exit 1); the macOS job uses it as the real
  assertion on `/bin/bash`. A check that has only ever passed is not evidence.
- CI job `portability-macos` — runs the gate, the portability scan and the plant matrix under
  `/bin/bash` (3.2), which is what a Mac cloner actually has. `/bin/bash` is called by absolute path
  so a Homebrew bash 5 earlier in `PATH` cannot make the job prove nothing.
- `checks/gate-redaction-probe.sh` — 14 leak shapes, each requiring the gate to FAIL *and* to keep
  the planted marker out of its output. Non-vacuous: it fails 14/14 against the revision that
  printed matched values. Wired into `checks/verify-all.sh` as a gate step.
- `checks/gate-plant-matrix-v3.sh` — 38 leak shapes (v2's 33 plus Q1–Q5 for the home-path classes
  below), pass/fail in both a UTF-8 locale and `LC_ALL=C`.
- `checks/gate-redaction-probe-v2.sh` — 19 shapes (v1's 14 plus multi-line commit and tag bodies,
  the non-placeholder peer key, and a file name matching a denylist REGEX entry). Wired into
  `checks/verify-all.sh` in place of v1; the v3 matrix replaces v2 there.
- `policy-cel` `--strict` — for pre-action use: `UNKNOWN` becomes `DENY` and a normal no-match applies
  `default_action` instead of `ALLOW`. Without it a no-match is a legitimate `ALLOW rule=none`, which is
  precisely what a regex over raw shell source cannot distinguish from a bypass (see the hardening-rules
  caveat: the bundled rules are advisory against shell *source*, not a structural control).
- `a2a-mesh/checks/verify.sh` phase 3c — 13 canned peer replies proving the task-state → exit-code
  mapping end to end (accept, terminal non-success, needs-action, unusable).

### Fixed
- **Allow-marker suppression could launder a second secret (external review, High).** The gate reported
  a `cofa:sanitise-allow` hit instead of failing it, the pre-push hook ran no allow control at all, and
  `checks/verify-allowed-hits.sh` keyed approvals on rule + path and then `sort -u`'d them — so a second
  marked secret in an already-approved file rode the first one's key. Approvals are now occurrence-specific:
  every hit carries a truncated SHA-256 of the matched line, and the control keys on rule + path:line +
  digest with no de-duplication. The baseline's own shape showed the size of the hole: **6 keys covered 66
  occurrences before; 66 keys cover 66 occurrences now.** Regression check: a second marked secret added to
  `.github/workflows/check.yml` must fail the control, and does — before this change it passed.
- **The pre-push hook did not scan what it was about to push (external review, High).** It recorded `HEAD`
  and never read the ref-update records git hands a pre-push hook, so the gate examined the checkout while a
  raw object could be published by object ID. The hook now reads every stdin record, creates a temporary ref
  at each pushed object, exports each pushed snapshot and scans it with the full tree rules, refuses a record
  it cannot parse, refuses a manual run (empty stdin) unless `COFA_PREPUSH_ALLOW_MANUAL=1`, and refuses
  unreachable objects — an unreachable object is pushable by OID and invisible to `git rev-list --all`.
  Proof: a secret on a branch that is not checked out, pushed by OID, is refused with the finding named.
- **Audit-write failures were silent (external review, Low).** Both audit appends ignored errors while
  `SECURITY.md` told operators to look for the record, so an unwritable or full destination produced an
  accepted push with no evidence. Every append is now verified and failure refuses the push; an audit
  destination inside the repository is rejected. Test: `COFA_PREPUSH_AUDIT=/dev/full` must exit non-zero.
- **Caller context could replace the command being inspected (external review, High).** `--context K=V`
  merged after the request fields and after the helper table, so `--context command=harmless` turned a
  denied `wipefs` command into `ALLOW rule=none`, and `--context matches=shadowed` made every bundled rule
  raise, dropping the decision to `default_action` — an attacker-triggerable ALLOW in a deployment whose
  operator believed the rules were in charge. Context entries named after a request field, a helper, or a
  decision are now refused with exit 2 and a reason, never silently dropped.
- **`SANITISATION.md` overstated the standalone gate's scope.** It claimed the gate scans unreachable
  objects; unreachable-object detection has always been a release-gate step. The limits section now says
  which control covers what, and `SECURITY.md` documents the hook's scope, its verified audit writes, and
  the fact that a clone without the hook installed has neither.
- **Multi-line commit and tag messages leaked through the finding printer.** The history scan
  prefixed a message with its carrier only on the first line, so a `cut -f1` on any later line
  printed the message body — the exact failure the redaction work exists to prevent. Every line of
  a message now carries its commit hash or tag ref (an `awk` prefix pass), so a finding names where
  the match is without reprinting what matched.
- **Five home-path shapes had no pattern at all** and passed silently: the macOS and Windows
  user-profile forms, capitalised and digit-first variants of the Linux home prefix, and the root
  home directory. One `HOME_RE` class is now used by every scan, mask and name check, so the tree scan, the history
  scan, the name scan and the mask shapes cannot drift apart again.
- **A non-placeholder peer key was printed verbatim.** The `peer-key-placeholder` finding named the
  real key found in `config.sample.yaml`; it now reports an ordinal and withholds the value.
- **Locale-dependent blind spot.** The binary rule ran under `LC_ALL=C` while the pattern scans ran
  under the caller's locale, so an invalid-UTF-8 text file was called text by one and skipped as
  binary by the other — every rule assumed another had covered it, and a real secret passed. The
  gate now pins one locale (`LC_ALL=C`) for every `grep`; all patterns are ASCII.
- **Redaction was partial.** A rule label is built from its pattern and an operator denylist entry
  *is* the private string, so `FAIL identity:<first 16 chars of the entry>` published what the check
  had just refused to publish; name, ref and symlink-target findings printed the name itself. Every
  line a finding prints now goes through one masking step: denylist matches (matched by *match*, not
  by pattern), absolute home paths and mail addresses are masked, and denylist labels are masked.
  `checks/gate-redaction-probe.sh` is the regression test.
- A2A client: a peer-controlled `status` that is not an object (`{"status": "completed"}`) crashed
  `send()` with an uncaught `AttributeError` (exit 1) instead of reporting an exit code. Same class
  as the non-string id defect, same treatment: anything that is not the expected shape resolves to
  "no usable state".
- The name scan no longer skips every path matching `*/.git*` — only the repository's own `.git`
  directory. A private name inside `.github/<name>/` or in a file called `.git<name>` was invisible.
- Relative symlinks that resolve outside the tree (or dangle) are refused; only absolute targets
  were checked before.
- History now covers file names and symlink targets, not just blob contents: a private file renamed
  before publish, or an absolute symlink committed and then deleted, was published unexamined
  (`git grep` does not search link blobs at all).

### Changed
- Gate output is redacted: a finding prints the file, the line and the rule class, never the matched
  value. A gate that prints the secret it found writes that secret into every CI log it fails in.
  Names, refs and symlink targets are masked too, and the mask keeps the first two characters and
  the length so the entry remains findable; a denylist rule is labelled by its masked form.
- A2A client exit codes: `ACCEPTED` (0) is now an **allowlist** — `SUBMITTED`, `WORKING`,
  `COMPLETED`. `NOT-ACCEPTED` (5) covers the terminal non-success states (`FAILED`, `REJECTED`,
  `CANCELED`, `CANCELLED`); new **`NEEDS-ACTION` (6)** covers the states that are paused *on the
  caller* (`INPUT_REQUIRED`, `AUTH_REQUIRED`), where the right move is to supply the input and
  continue the same task id rather than resend. A real task id with an unknown, empty, missing or
  non-string state is `BAD-RESPONSE` (4) with the id printed. Spellings are normalised
  (case, `-` → `_`, a `TASK_STATE_` prefix is stripped), and 4/5/6 report on stderr.
- `a2a-mesh/checks/verify.sh` rewrites its temp config with a portable write-then-move instead of
  `sed -i`, which is GNU-only and fails on the macOS runner.
- A2A-style JSON-RPC client (v1.0 `SendMessage` dialect): `SendMessage` responses are
  unwrapped defensively — `result.task` (v1.0),
  `result.message` (the oneof), or a pre-1.0 bare task/message. A result carrying no task or
  message id is now `BAD-RESPONSE` (exit 4) instead of a silent `ACCEPTED`, and such a reply is
  never retried because the task may already have been delivered.
- Long-term-memory documentation describes the shipped client truthfully: standard library plus
  PostgreSQL (`psycopg2` when present, `psql` otherwise). The `provider` field is platform
  metadata, not something the shipped client reads.
- `checks/verify-portability.sh` covers the whole bash-3.2 class instead of 10 spellings, and finds
  shell files by **shebang** as well as by `.sh` name. 27 patterns now (`;&`/`;;&`, `|&`,
  `declare`/`local -n`, `declare -g`/`-gA`, negative array indexes, fractional `read -t`, `wait -n`,
  `printf '%(…)T'`, `${v@Q}`, `EPOCHSECONDS`, `lastpipe`, `inherit_errexit`, `${v^}`, `[[ -R ]]`),
  so a construct like `;&` or `EPOCHSECONDS` can no longer pass a check that was green on the
  narrow list. The shebang branch closes the other half of the hole: a script with no `.sh` suffix
  (a hook sample, a vendored file) was never opened, so a bash-4 builtin inside one shipped
  unscanned. Its selftest proves both directions — it must flag an extensionless script, and it must
  NOT open a file whose shebang is not a shell — and the header names its blind spots (it is a
  static pattern check; it cannot see the quoted-mask or empty-array runtime differences). Local
  backup noise (`*.orig`, `*.bak`, `*~`, which `.gitignore` already keeps out of the repo) is
  skipped: it is not a shipped artifact.

- The regression matrix moved to `checks/gate-plant-matrix-v4.sh` (41 shapes), run by both the
  release check and the CI macOS job. W1–W3 pin the round-10 worktree fix: a `.git` pointer file
  must not alarm, the exclusion must not blind the gate to a leak planted beside it, and it must not
  extend to a symlink named `.git`. The macOS step *ran* v4 from the moment it was wired while its
  label still claimed the v3 matrix — a label can lie where a command cannot, and only reading the
  job's log showed it.
- `checks/pre-push.sample` prints an audit line before the gate runs — HEAD, gate hash, overlay
  state, pusher — and appends it to `$HOME/.cofa-pre-push-audit.log`. A run without
  `checks/denylist.local` checks the shipped pattern classes only: it WARNs, and a WARN scrolls
  past, so the overlay's state is recorded rather than inferred from silence.
- The audit record is now **two lines, both written even when the push is refused**. The attempt line
  carries the overlay proof *and the prover's verdict*; the RESULT line carries the gate's own
  verdict plus `findings=<count>` and the distinct `rules=` labels — no file paths, no line numbers,
  no matched text — so a refused push and an accepted one no longer look identical in the audit file.
  A gate that cannot run at all is recorded as `ERROR(rc=2)`, never as silence. Any non-zero from the
  prover refuses the push, **exit 2 included**: "no overlay to prove" is an unproven gate, not a pass
  (external review, rounds 15–16).
- The v4 plant matrix (44 plants) now covers the widened `.git*` exclusion. A **committed**
  `.gitignore`/`.gitmodules` plant is read by the history scan, which does not use the name exclusion,
  so it masks the mutant: the shapes that guard the tree-side exclusion are **left uncommitted**, or
  use a class the history scan lacks (`hex-secret`, `bearer-literal`, `b64-blob`). Both mutants flip
  as intended — the `.git*` widening misses exactly those two shapes, and the live gate still catches
  them. `MATRIX: PASSED — 44 plants, 0 problems`.
- **Known residual risk, documented rather than fixed:** `git push --no-verify` bypasses the hook and
  leaves no audit line. Before any visibility flip, confirm the tip of `main` has a matching
  `result=ACCEPTED` line; CI is the backstop for the shipped pattern classes, not for the private
  overlay.

### Notes for the first public release
- The CI workflow now runs on GitHub, and did so before this release: it was first validated locally
  with `checks/verify-all.sh --require-all` on both client paths, and every push since has exercised
  the YAML itself. Latest: run `38202234498` on `4667966` — **success**, 2m42s, all five jobs
  (`portability-macos` plus four `verify` legs: Python 3.9/3.12 × psycopg2/psql).
- Agent-to-agent behaviour is verified against the shipped loopback peer only. A third-party A2A
  v1.0 peer is not exercised by the test suite.
- No release tag has been created; `git tag v0.1.0` is the release step.
- The `portability-macos` job has now run on GitHub. Run `38202234498` reports
  `GNU bash, version 3.2.57(1)-release (arm64-apple-darwin25)` on `macos-26-arm64`, `ok: /bin/bash is
  bash 3.2.57(1)-release` from `checks/assert-bash-major.sh /bin/bash 3`, and
  `plants run: 41   problems: 0` / `MATRIX: PASSED` from the v4 matrix under that shell. The macOS
  claim is no longer an untested assertion.
