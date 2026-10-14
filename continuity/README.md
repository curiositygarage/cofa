# Continuity Component

**Checkpoint + resume.** A written file becomes ground truth after a restart so the agent picks up exactly where it left off — no reconstructing from memory.

---

## What it does

Maintains a checkpoint file that records:
- **Title**: what the current task is called
- **State**: where things stand right now
- **Next step**: the immediate next action
- **Phase**: ACTIVE or IDLE (controls whether auto-resume triggers on wake)

After a crash, restart, or unexpected termination, the agent reads this file first. It becomes the source of truth — not guessing, not scanning history, not improvising.

---

## Install

### Prerequisites

None beyond a filesystem with write access to the agent's home directory.

### Steps

1. Copy the sample directory structure:

```bash
mkdir -p ~/.config/cofa/continuity/checkpoints
mkdir -p ~/.config/cofa/continuity/resume
cp config.sample.yaml ~/.config/cofa/continuity/config.yaml
```

2. Edit `~/.config/cofa/continuity/config.yaml` — set the paths for checkpoints and resume files. Defaults to standard locations under `~/.config/cofa/continuity/`.

3. **Register the checkpoint watcher.** On wake, the agent must read `~/.config/cofa/continuity/resume/LAST_TASK.md` (or the configured path) before doing anything else. Your platform may have a native startup-hook API — use it if available. If not, the mechanism IS the file itself: just make sure every new session reads this file first. No hook required; the convention of reading it on wake is sufficient.

4. Verify the checkpoint mechanism:

```bash
./checks/verify.sh
```

### Configuration reference

See `config.sample.yaml` for every supported field. Key fields:

- `checkpoints_dir`: Directory for saved checkpoint files
- `resume_file`: Path to the active LAST_TASK.md
- `auto_resume_phase`: Default phase value ('ACTIVE' triggers auto-resume, 'IDLE' does not)
- `checkpoint_interval_seconds`: How often to auto-save during active work

---

## Usage

The shipped client is the convention — it writes the file atomically and gives the wake path a
decision to read, instead of every platform hand-rolling JSON:

```bash
# Before substantive work, and before any platform restart:
python3 lib/checkpoint.py save --title "<TITLE>" --state "<STATE>" --next "<NEXT STEP>" --phase ACTIVE

# On wake (or from a startup hook) — exit 0 only when there is something to resume:
python3 lib/checkpoint.py resolve

# Work finished:
python3 lib/checkpoint.py clear
```

`resolve` prints `RESUMABLE:` plus the recovered `title`/`state`/`next`, or `NOT-RESUMABLE:` with
the reason and a non-zero exit. A wake path that reads that exit code never has to parse prose.

On wake, read this file FIRST — it is ground truth. If it is missing, fall back to the last entry
in your platform's own notes/log file and say so explicitly.

### Phase discipline

`--phase ACTIVE` is REQUIRED for auto-resume. Omitting it writes `IDLE` and the watcher correctly refuses to resume. Auto-resume only fires when the phase field equals `"ACTIVE"` — this is a safety gate, not optional metadata.

---

## Verify

Run `./checks/verify.sh`. It performs a real save and a cold read in a separate process — the
thing that actually has to work after a restart:

- the shipped sample config still documents `resume_file` and `checkpoints_dir`
- the deployed config loads (an unusable config fails; "nothing to resume right now" does not)
- `save` writes a valid JSON checkpoint **at the configured path** and also snapshots history
- a **new process** reading the file recovers `title`, `state` and `next` — the restart test
- **negative:** an `IDLE` checkpoint is refused for auto-resume (exit 1) with the phase named
- **negative:** after `clear`, `resolve` refuses (exit 1) and the file is gone
- `~` in a config path is expanded against `HOME` (no literal `~` directory is created)
- the verifier re-runs itself with an empty config dir and requires that run to FAIL

Exit code 0 = a checkpoint survives a cold read and phase discipline is enforced. Non-zero =
which check failed is printed.

---

## Rollback

1. Remove the config and data: `rm -rf ~/.config/cofa/continuity/`
2. Remove the startup hook from your platform configuration.
3. Restart your agent platform.

No data loss risk: checkpoints are additive. Removing this component simply means the agent starts fresh on wake — which is its normal behaviour anyway, just without the advantage of prior-state memory.
