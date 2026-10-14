# Policy Layer Component (CEL)

**CEL policy-as-code evaluation engine.** Declarative rules that evaluate before actions, preventing operations that violate policy.

---

## What it does

Provides a Common Expression Language (CEL) evaluation layer that runs policy checks against action contexts. Instead of hard-coding allow/deny logic in your agent's control flow, you write declarative rules in CEL format and let the engine evaluate them at runtime.

Includes three hardened rule patterns that close known policy leak vectors discovered in earlier deployments.

---

## Install

### Prerequisites

- **Python 3.9+**. No package download is required: the component ships its own CEL-subset
  evaluator (`lib/policy.py`, standard library only), so an install works offline.
- Optional: if you prefer full CEL, install a CEL library (`pip install cel-python`) and adapt
  `lib/policy.py` — the rule files are plain expressions and stay readable either way.

### Steps

1. Copy the sample config and the rule set:

```bash
mkdir -p ~/.config/cofa/policy-cel/rules
cp config.sample.yaml ~/.config/cofa/policy-cel/config.yaml
cp rules/*.cel ~/.config/cofa/policy-cel/rules/   # copy the CONTENTS, not the directory
```

2. Edit `~/.config/cofa/policy-cel/config.yaml` — `rules_dir` is resolved **relative to the
   config file** when it is not absolute, so `./rules/` means `~/.config/cofa/policy-cel/rules/`.

Re-running these steps must be safe: `cp -r rules ~/.config/cofa/policy-cel/rules` on an existing
install nests a `rules/rules/` copy that the engine never loads, so a rule edit would silently
appear to have no effect.

3. Review and optionally extend the rules. Do not edit the built-in hardened rules unless you
   understand the attack patterns they prevent — see "The three hardening fixes" below.

4. **Register the pre-action hook.** Ask the engine for a verdict before executing:

```bash
python3 lib/policy.py decide --command "the exact shell command"
# VERDICT: DENY rule=wipefs_protection reason=...
```

   `decide` exits 0 whenever a verdict was produced; the verdict word is the decision.
   It exits **4** when no rule set can be loaded, so a missing rule set can never be read as
   "allow". Wire that call into whatever pre-execution hook your platform provides; if there
   is no hook API, call it from a wrapper around your shell executor.

   **Pass supplementary context, never the inspected fields.** `--context K=V` is repeatable, and
   reserved names are **refused** (exit 2) rather than merged: `command`, `tool`, `path`, the helper
   names rule bodies call, and the decision names reported back. Context is merged last, so without
   that guard a caller could pass `--context command=harmless` and replace the very text a rule was
   about to inspect — a `wipefs` DENY became `ALLOW rule=none` with no rule changing — or shadow a
   helper (`--context matches=shadowed`) so every bundled rule raised and the UNKNOWN path returned the
   configured `default_action`, i.e. an attacker-triggerable ALLOW in a deployment whose operator
   believed the rules were protecting them.

   **`--strict` for pre-action use.** A no-match is ALLOW with `rule=none`, and UNKNOWN follows
   `default_action`. `--strict` moves both toward refusal: UNKNOWN becomes DENY, and a no-match applies
   `default_action` instead of ALLOW. State plainly what it does **not** do: rules still match raw
   command text *lexically*, so a strict run is a tighter default, not a structural guarantee — see
   "What this layer does not defend against" at the end of this file.

5. Verify the engine:

```bash
./checks/verify.sh
```

### Configuration reference

See `config.sample.yaml` for every supported field. Key fields:

- `engine`: CEL engine identifier (library name)
- `rules_dir`: Path to the directory containing CEL rule files
- `default_action`: What happens when a rule evaluates to UNKNOWN — `ALLOW`, `DENY`, or `REPORT`
- `log_level`: Verbosity of policy evaluation logs

---

## Supported expression subset

Rules are `*.cel` files; each file holds one or more `[rule_name]` blocks:

```
[wipefs_protection]
verdict = DENY                       # DENY | ASK | REPORT
reason  = why this invocation needs a human
when    = matches(command, "\\bwipefs\\b")
```

`when` is evaluated against the request context — `command`, `tool`, `path`, plus anything you
pass as `--context K=V`. Supported syntax:

- Booleans and grouping: `true`, `false`, `&&`, `||`, `!`, `( … )`
- Comparisons: `==`, `!=`, `<`, `<=`, `>`, `>=`, `in [ … ]`
- Helpers: `matches(s, regex)`, `contains(s, sub)`, `startsWith`, `endsWith`, `lower`, `upper`, `size(s)`
- String, number, boolean and list literals

Anything outside that subset is **not** silently ignored: the rule is marked UNKNOWN and
`default_action` applies, which is reported as `rule=unknown`. Calls other than the documented
helpers are rejected before evaluation — a rule cannot smuggle code into the engine.

Decision order: the first matching `DENY` wins, then `ASK`/`REPORT`; when no rule matches the
verdict is `ALLOW rule=none`. `default_action` applies only to UNKNOWN, not to "no rule matched".

---

## The three hardening fixes

These rules are bundled and must remain enabled. They close specific policy bypass patterns:

### Fix 1: `wipefs` protection

Prevents `wipefs`, `dd`, `mkfs`, `shred`, `truncate --size 0`, and any command targeting disk device paths (`/dev/sd*`, `/dev/nvme*`, `/dev/vd*`). Evaluated as a string-match rule against the first token of any shell-executed command.

**Leak closed**: an agent calling a destructive utility directly through the shell executor bypassed the original high-level permission check that only inspected the command *argument* list, not the full invocation.

### Fix 2: `/etc` redirect protection

Prevents redirection (shell `>` operator) of output into `/etc/*` or any subdirectory thereof. This catches attempts to overwrite system configuration files via shell pipelines even when the primary command is benign (e.g., `echo "modified" > /etc/crontab`).

**Leak closed**: the original policy only checked the command name, not the redirection targets. A harmless-looking echo or tee could rewrite system files through shell operators.

**Whitespace tolerance**: the rule must match regardless of whitespace between `>` and the path. All variants work:
- `echo "modified" > /etc/crontab` — direct redirect
- `echo "modified" >  /etc/crontab` — extra space
- `echo "modified" >	/etc/crontab` — tab character

### Fix 3: chmod flag tolerance

The `chmod` deny rule correctly handles flags between `chmod` and the mode argument. Examples all match:
- `chmod 777 /path` — direct mode
- `chmod -R 777 /path` — with `-R` flag
- `chmod --recursive 777 /path` — with long flag
- `chmod 000 /path` — any numeric mode

The rule uses a flexible pattern: `chmod` followed by zero or more flags, then a numeric octal mode (3+ digits), then a path.

**Leak closed**: the original pattern was `chmod\s+\d{3}\s+` which missed `chmod -R 777` because the `-R` token sat between `chmod` and `777`.

---

## Verify

Run `./checks/verify.sh`. It does not look for the word "wipefs" in this documentation — it runs
commands through the evaluator and asserts the verdict:

- the repository actually ships `rules/*.cel` (an empty component fails)
- the deployed config loads and its `rules_dir` resolves to a real rule set
- `wipefs`, `mkfs`, `shred` and `dd` invocations are DENIED
- redirects into `/etc` are DENIED, including with extra spaces and tab characters
- `chmod 777`, `chmod -R 777` and `chmod --recursive 777` are DENIED
- control cases: a benign command and a symbolic `chmod +x` are ALLOWED (the engine is not a blanket denial)
- **non-vacuity:** delete a rule from a temp copy and the verdict for that command changes — so the answer comes from the rules, not from code
- an unevaluable rule escalates to `default_action` and is reported as `rule=unknown`
- a missing rule set exits 4 rather than silently allowing
- the verifier re-runs itself with an empty config dir and requires that run to FAIL

Exit code 0 = the shipped rules load and enforce. Non-zero = which check failed is printed.

---

## Rollback

1. Remove the config: `rm -rf ~/.config/cofa/policy-cel/`
2. Unregister the pre-action hook in your platform configuration.
3. Remove the CEL library if desired: `pip uninstall cel-python`
4. Restart your agent platform.

The bundled rules are immutable; do not attempt to disable them individually.
