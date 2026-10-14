# Common Operation Framework for Agent (COFA)

**Platform-agnostic maturity layer.** Takes any bare agent platform — hosted or self-run, open or closed source, or anything with an LLM behind an agent loop — to operational maturity in the shortest possible time.

Installing the agent is easy. Maturing it (memory, policy, comms, continuity) is what takes weeks. COFA is that missing layer.

---

## What you get

| Component | Folder | What it does |
|---|---|---|
| **Long-Term Memory** | `long-term-memory/` | Local-first recall via mem0 + PostgreSQL. Namespaced per agent. No cloud dependency. |
| **CEL Policy Layer** | `policy-cel/` | Policy-as-code rules that evaluate before actions. Hardened against three known pattern leaks. |
| **A2A Mesh Client** | `a2a-mesh/` | A2A client (pre-1.0 message shape under the v1.0 method name) — wiring and conventions. Enables two agents to exchange tasks reliably. |
| **Continuity** | `continuity/` | Checkpoint + resume so a restart picks up the right task from a written file. Ground truth after crash. |

All four are **independently installable**. You may only need one.

---

## Why this matures your platform

Without COFA, a fresh agent has code execution but no durable recall, no policy guardrails, no peer messaging, and no memory across restarts. Adding these piecemeal wastes time because the patterns repeat across platforms. COFA packages them as drop-in, self-contained units whose README tells you exactly what to change, how to verify it works, and how to roll back if something goes wrong.

The net effect: a platform that behaves like one it's been running for months instead of hours.

---

## How to navigate

### Quick start

```
git clone https://github.com/curiositygarage/cofa.git ~/projects/cofa
cd ~/projects/cofa
```

Read `SETUP-GUIDE.md` first — it presents the options through whatever surface your host offers (terminal TUI, web UI, or desktop app). Then install whichever component(s) you need.

### One at a time

Each component folder is fully self-contained. Go there, read its README, and follow the steps. No ordering requirement. No cross-component dependencies.

### All at once

Run the setup guide's "install everything" branch and it will walk through each component in sequence, verifying after each.

### Verification

Every component ships `checks/verify.sh`. Run it after installation. It exercises the component's
own shipped client end-to-end and fails loudly (non-zero exit) when the component is missing or
broken. Each verifier also re-runs itself with an empty config directory and **requires that run
to fail**, so a verifier that could never fail is caught rather than trusted.

To run every component in one pass (the release check):

```
checks/with-scratch-postgres.sh checks/verify-all.sh --require-all
```

The wrapper provisions a throwaway PostgreSQL cluster (initdb in a temp dir, trust auth, unix
socket only, no TCP listener), exports the `COFA_TEST_PG_*` interface, runs the command, and
destroys everything — the long-term-memory check needs a real server to verify against. Run
`checks/verify-all.sh --require-all` **without** the wrapper and that component reports
`NOT VERIFIED` and the run exits non-zero. That is the check being honest about what it could not
verify, not a broken repository.

### Rollback

Each component README includes rollback instructions. If something breaks, remove the files, restore the backup, restart — done.

---

## Repository layout

```
README.md              ← you are here — the map
SETUP-GUIDE.md         ← interactive guide content (renders natively)
LICENSE                ← MIT
KEYS-REQUIRED.md       ← every credential any component needs
SANITISATION.md        ← rules + the single pre-push gate
bin/                   ← the single pre-push gate, shipped in-repo
checks/pre-push.sample ← the gate's trigger; writes a two-line push audit to
                         $HOME/.cofa-pre-push-audit.log (see SECURITY.md for what it does not cover)
long-term-memory/      ← mem0 + PostgreSQL recall   (lib/memory.py, checks/verify.sh)
policy-cel/            ← CEL-subset policy engine   (lib/policy.py, rules/*.cel, checks/verify.sh)
a2a-mesh/              ← A2A client (pre-1.0 shape) (lib/a2a_client.py, checks/verify.sh)
continuity/            ← checkpoint + resume        (lib/checkpoint.py, checks/verify.sh)
```

Each component installs to `${COFA_CONFIG_DIR:-$HOME/.config/cofa}/<component>/config.yaml` and
carries its own `README.md`, `KEYS-REQUIRED.md`, `config.sample.yaml` and `checks/verify.sh`.

---

## Status

**Milestone M2:** all four components ship a working reference implementation, a rule/artifact
set, and a verifier that fails when the component is absent and passes when it is installed.
Installations write to `${COFA_CONFIG_DIR:-$HOME/.config/cofa}/<component>/`.

## License

MIT — see `LICENSE`. Copyright: Curiosity Garage, 2026.
