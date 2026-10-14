# bin/ — Repository Scripts

Only small, self-contained scripts live in this directory. These are tools so lightweight they belong in the git tree rather than being downloaded.

## What belongs here

- Utility scripts <150 lines that serve the repository as a whole
- Helper programs with zero runtime dependencies beyond what COFA already requires (`bash`, `grep`, `find`, `python3`)
- Short-lived diagnostic tools used during installation or verification

## What does NOT belong here

- Large binaries (use GitHub Releases instead)
- Binaries with external dependencies (pin them in `<component>/downloads/`)
- Scripts that are specific to one component (those stay in `<component>/checks/`)

## The one script that is here

### `scan-sanitisation.sh`

The repository's **single** pre-push sanitisation gate. Do not add a second scanner: two gates
that disagree are worse than one that fails.

```bash
bin/scan-sanitisation.sh             # exit 0 clean · exit 1 findings · exit 2 usage/internal error
bin/scan-sanitisation.sh --selftest  # plant a canary (must be caught) + a clean tree (must pass)
bin/scan-sanitisation.sh <path>      # scan a specific directory
```

Design rules it follows — keep any future helper to the same standard:

1. **It must be able to fail.** `--selftest` plants a canary and requires a non-zero exit, then
   requires a clean tree to pass. A scanner that only ever prints "clean" is not a guard.
2. **Count findings in the current shell.** Piping a scan loop into a subshell silently discards
   the counter — the defect that made an earlier version of this gate report FAIL lines and exit 0.
3. **No private literal lives in the repository.** Pattern *classes* are fine; operator strings
   (names, hosts, peer ids, private paths) go in `checks/denylist.local`, which is git-ignored.
4. **Allowlist explicitly.** A line that genuinely must mention a forbidden pattern carries
   `cofa:sanitise-allow`.
