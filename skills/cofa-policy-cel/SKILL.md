---
name: cofa-policy-cel
description: Use when agent actions need declarative allow/deny rules evaluated before execution. CEL policy-as-code with a hardened rule baseline and offline evaluation.
license: MIT
---

# COFA — Policy Layer (CEL)

Policy-as-code for pre-action checks. Instead of scattering allow/deny conditionals through an
agent's control flow, rules are written as Common Expression Language expressions and evaluated at
runtime against the action context. Ships a rule baseline that covers the destructive-command and
path-escape classes that name-matching checks miss.

Source: https://github.com/curiositygarage/cofa (component: `policy-cel/`)

## Use this when

- The agent can execute shell commands, write files, or touch infrastructure and needs a gate that
  is separate from the model's judgement.
- You want the rules reviewable as text, diffable, and versioned, not buried in code.
- You need evaluation with no network and no third-party runtime.

## Install

Python 3.9+ standard library. The component ships its own CEL-subset evaluator, so it works offline.
If you prefer full CEL, install `cel-python` and adapt `lib/policy.py`; the rules stay plain
expressions.

Run these from the component directory (`policy-cel/`); the sample config and `rules/` live there,
not at the repo root.

```bash
cd policy-cel         # from the repo root
mkdir -p ~/.config/cofa/policy-cel/rules
cp config.sample.yaml ~/.config/cofa/policy-cel/config.yaml
cp rules/*.cel ~/.config/cofa/policy-cel/rules/
```

`rules_dir` resolves relative to the config file when not absolute. Re-running the copy must be
safe: `cp -r rules <dir>/rules` on an existing install nests `rules/rules/`, which the engine never
loads, so a rule edit silently has no effect.

## Usage

```bash
python3 lib/policy.py decide --command "the exact shell command"
# VERDICT: DENY   rule=... reason=...
# VERDICT: ASK    rule=... reason=...
# VERDICT: REPORT rule=... reason=...
# VERDICT: ALLOW  rule=none reason=no rule matched
```

**Four verdicts, not three** (`policy.py:45`: `VERDICTS = ("DENY", "ASK", "REPORT", "ALLOW")`). A
wrapper that branches on ALLOW/ASK/DENY and treats anything else as a catch-all mishandles
`REPORT`, which means: a rule matched and wants a human told, but nothing was refused.

The resolution order is worth knowing before you write rules (`policy.py:210-220`):

- **`DENY` short-circuits.** Any matching DENY rule decides the result on the first pass.
- **Otherwise the first matching `ASK` or `REPORT` wins, in load order** — files are read in sorted
  filename order (`policy.py:177`) and rules in file order. `ASK` is *not* ranked above `REPORT`:
  with an ASK rule at `50-x.cel` and a REPORT rule at `60-y.cel`, the REPORT is what comes back.
  So make the intended precedence explicit in the filenames.
- **`ALLOW` is what is left**, not a rule verdict: no rule matched (`ALLOW rule=none`) or the
  engine found nothing to deny.

Exit codes carry meaning, and the verdict word is the decision:

- `0`: a verdict was produced (deny, ask, report, or allow).
- `2`: usage error, including a reserved context field passed to `--context`.
- `4`: **no rule set could be loaded.** Treat this as deny-equivalent. A missing rule set must never
  read as "allow".

Wire `decide` into whatever pre-execution hook the platform exposes. With no hook API, wrap the
shell executor: no command runs without a verdict.

## Rules that matter

The shipped baseline exists because checks that only look at the command *name* are bypassed by
aliases, absolute paths, interpreters, and shell chaining. Extend the rule set; do not narrow the
baseline unless you can say which attack each removed rule prevented.

## Pitfalls

- **A gate that fails open is decoration.** Exit 4 must block. Test it by moving the rules directory
  away and confirming the action is refused, not permitted.
- **Pass supplementary context, never the inspected fields.** Reserved names (`command`, `tool`,
  `path`) are refused rather than merged, so a caller cannot overwrite the thing being judged.
- **Rules drift from reality.** A policy that denies a path that no longer exists, or allows a tool
  you since retired, teaches everyone to bypass the gate. Re-read the rules when the toolset changes.
- **Evaluate the exact string you will execute.** Checking a normalised or display form of a command
  and then running a different string is the classic gap.
- **A no-match verdict is ALLOW, not DENY.** `rule=none` means the shipped baseline has no rule for
  that command — `default_action` applies to UNKNOWN, not to no-match (`README.md`, "verdict is
  ALLOW rule=none"). So the baseline is a tripwire over the destructive shapes it names, not a
  fail-closed gate over arbitrary commands. Never describe it as one, and never put an uncovered
  command in a Verify step expecting DENY: `rm -rf /` is not covered and returns `ALLOW rule=none`.

## Verify

Run these from the component directory (`policy-cel/`); `./checks/verify.sh` does not resolve from
the repo root.

```bash
cd policy-cel                                              # from the repo root
./checks/verify.sh
python3 lib/policy.py decide --command "mkfs.ext4 /dev/sdb1"   # expect DENY  (wipefs_protection)
python3 lib/policy.py decide --command "chmod -R 777 /"        # expect DENY  (chmod_flag_tolerance)
python3 lib/policy.py decide --command "ls -la"                # expect ALLOW (no rule matched)
python3 lib/policy.py decide --command "rm -rf /"              # expect ALLOW rule=none — rm is NOT in the baseline
```

MIT licensed. See `LICENSE`.
