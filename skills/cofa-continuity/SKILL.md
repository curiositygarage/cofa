---
name: cofa-continuity
description: Use when an agent must resume the right task after a crash or restart instead of guessing. A written checkpoint file becomes ground truth on wake.
license: MIT
---

# COFA — Continuity (checkpoint and resume)

One file records what the agent was doing, where it got to, and the next action. After any restart,
crash, or context loss the agent reads that file **first** and continues. No reconstructing the task
from memory, no scanning old transcripts, no improvising.

Source: https://github.com/curiositygarage/cofa (component: `continuity/`)

## Use this when

- The agent runs long tasks and the host, process, or session can die mid-task.
- Several tasks can be in flight and a restart must not silently resume the wrong one.
- You want the resume decision to be inspectable by a human before it happens.

## Install

```bash
mkdir -p ~/.config/cofa/continuity/checkpoints ~/.config/cofa/continuity/resume
cp config.sample.yaml ~/.config/cofa/continuity/config.yaml
```

Edit `resume_file` and `checkpoints_dir` if you do not want the defaults. Python 3.9+ standard
library only; no packages.

## Checkpoint fields

- `title`: what the task is called.
- `state`: where it stands right now, in enough detail to act on.
- `next_step`: the immediate next action, not a plan.
- `phase`: `ACTIVE` or `IDLE`. Only `ACTIVE` should trigger auto-resume on wake.

## Usage

```bash
python3 lib/checkpoint.py save --title "<task>" --state "<where it stands>" --next "<next action>" --phase ACTIVE
python3 lib/checkpoint.py clear
```

Save at the start of substantive work and before any planned restart. `clear` when the work is
genuinely finished, not when it is merely paused.

## Wake behaviour

On start, read the resume file before anything else and treat it as authoritative. If it says
`ACTIVE`, resume that task in that context. If it is absent, fall back deliberately (last log entry)
and say so out loud rather than pretending the task was never running.

## Pitfalls

- **Checkpointing after the fact is useless.** The save must happen before the risk, not on the way
  out of a working session; a crash gives no exit path to write on.
- **A vague `state` line is a fake checkpoint.** "Working on the report" resumes nothing. Write the
  measured state: what is done, what is verified, what is blocked and on whom.
- **Stale checkpoints resume wrong work.** Clear it when the task closes, and overwrite it when the
  priority changes. Do not leave several plausible ACTIVE files around.
- **Auto-resume needs a phase, not a flag.** Omitting the phase must default to non-resuming, so an
  interrupted save cannot silently restart work nobody asked for.
- **Atomic write.** Write to a temporary file and rename, or a crash mid-write leaves a truncated
  checkpoint that resumes nothing.

## Verify

```bash
./checks/verify.sh
```

Then save a checkpoint, kill the process, start it again, and confirm the resume path reads the same
title, state and next step.

MIT licensed. See `LICENSE`.
