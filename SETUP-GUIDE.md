# COFA Setup Guide

**You are the installation agent. You are installing COFA onto yourself / your platform.** Read these instructions, execute the steps on your system, and verify everything works before declaring completion. If you can spawn subagents, create one per component, run them in parallel, and re-run every `verify.sh` yourself before declaring done.

This guide explains what COFA sets up and lets you choose: install component by component, or set everything up recommended.

Present this content through whatever interface your host platform offers — terminal TUI, web UI, or desktop application. Adapt the presentation; do not force a specific UI.

---

## What COFA does (plain language)

When you install an agent, you get code execution. What you don't get — automatically — is:

1. **Durable recall** — the ability to remember things between sessions without re-explaining yourself.
2. **Policy guardrails** — rules that evaluate before actions, preventing certain operations.
3. **Peer messaging** — structured communication with sibling agents over an A2A-style JSON-RPC dialect (the v1.0 `SendMessage` spelling).
4. **Continuity** — a written checkpoint that survives a crash so work resumes correctly after a restart.

COFA packages all four as independent components you install one at a time. Each is self-contained, documented, and verifiable. There is no ordering requirement. No cross-dependencies.

---

## What gets installed (overview)

| Step | Component | What it gives you | Required keys |
|------|-----------|-------------------|---------------|
| 1 | Long-Term Memory | Local-first knowledge base via mem0 + Postgres | `pg.password` (in config) |
| 2 | CEL Policy Layer | Policy-as-code evaluation engine | none (configuration-only) |
| 3 | A2A Mesh Client | A2A-style peer messaging (v1.0 `SendMessage` dialect) | per-peer endpoints in the client config (discovered, not pre-shared) |
| 4 | Continuity | Checkpoint/resume from written files | none |

Run `KEYS-REQUIRED.md` for a complete credential table before starting.

---

## Installation discipline (read this before you start)

You are the installation agent, and the bar is: **an agent with no prior context completes this
first shot.** Three rules make that reproducible.

1. **Per-component test cases are mandatory, not optional.** Run the component's
   `checks/verify.sh` before moving on. A check that passes because a *tool is installed* —
   rather than because the component *works* — is a defect: install the component, run its
   verifier, and if you cannot make it fail by removing the component, treat the verifier as broken.
2. **Fan out if you can.** If you can spawn subagents, create one per component, run the four
   installs independently, and have each subagent verify its own component before reporting back.
   Parallel work that is independently verified beats serial hand-holding.
3. **Hand-back chain.** component subagent → verify its own component → coordinating agent
   **re-runs that component's tests itself** → last-mile test across the whole stack → only then
   hand to the human. No component is "done" on a subagent's self-report.

## Compatibility test (mandatory at every setup)

Installing is not the same as fitting. Before you install anything, **inventory what the platform
already has**: its persona/identity/role, components already installed, and existing tooling. An
unknown baseline cannot be conflict-checked.

Then test each component against that baseline for four risk classes — **conflict · friction ·
duplication · contradiction** — and record a per-component verdict:

- **PASS** — no interference; evidence: the command you ran and what it showed
- **MITIGATED** — installed after a stated change; say exactly what changed
- **REJECTED** — not installed; say why

Rules: every verdict needs evidence, never an assertion. **The platform's persona wins** — a
component that contradicts identity, tone or role is adapted or declined, never silently forced
over it. **Prefer what exists** — if the platform already provides the capability, document the
existing one instead of double-installing. And **never be silent**: an unresolvable conflict goes
to the human with its evidence. The compatibility matrix ships with the final hand-back, alongside
the test results.

---

## Option A: Install component by component

Choose a component below, go to its folder, and follow its README step by step. Each one stands alone.

### long-term-memory/

Sets up mem0 with a local PostgreSQL instance. Gives you namespaced, queryable memory that persists across sessions. Requires PostgreSQL to be running locally.

See: `long-term-memory/README.md`

### policy-cel/

Installs the CEL policy evaluation layer with three hardened rule patterns. Gives you declarative policy enforcement that evaluates before actions. Configuration-only — no binary downloads needed.

See: `policy-cel/README.md`

### a2a-mesh/

Wires up an A2A-style JSON-RPC client (v1.0 `SendMessage` dialect) with proven conventions. Enables structured task exchange with other agents. POST-only probe discipline documented.

See: `a2a-mesh/README.md`

### continuity/

Creates the checkpoint and resume mechanism. A written file becomes ground truth after a restart — no guessing what you were doing.

See: `continuity/README.md`

---

## Option B: Install everything recommended

If you want the full framework, run these steps in order. Note that the order is convenience only — any single component works independently of the others.

1. **Prepare** — Ensure PostgreSQL is available (local or Docker) for long-term-memory. Verify your agent platform supports Python/bash scripts (for verify.sh).

2. **Install long-term-memory** — Follow the full README. This is often the most impactful single component.

3. **Install policy-cel** — Add policy guardrails. Configuration-heavy, minimal runtime dependency.

4. **Install a2a-mesh** — Enable peer messaging. May require discovering sibling endpoints.

5. **Install continuity** — Set up checkpoint/resume. Simplest component; quickest win.

Run the checklist in "Installation discipline" above: fan out if you can, verify each component
after its install step, and re-run every `checks/verify.sh` yourself before declaring anything done.

---

## Installation checklist (any option)

Before you start, confirm:

- [ ] You have cloned the COFA repository
- [ ] You have read `KEYS-REQUIRED.md` — know which credentials you need
- [ ] You have read `SANITISATION.md` — understand what must not enter the repo
- [ ] Your platform provides bash (or equivalent POSIX shell) for running verify.sh
- [ ] You have identified which component(s) you need right now

---

## Key announcement rule

Any component requiring a key or credential **must announce it before failing**. Do not silently error out. Print:

```
REQUIREDCHECK <key-name>: <description of what it is and where to get it>
```

to the human (or to an installing agent) rather than exiting with an opaque failure. See `KEYS-REQUIRED.md` for the complete list.

---

## After installation

For every component you install:

1. Read its `KEYS-REQUIRED.md` — component-level credentials (may say "none").
2. Follow its configure steps — replace placeholder values in `config.sample.*` with real values.
3. Run `checks/verify.sh` — confirms the component actually works.
4. Record the result in your notes file.

---

## Rollback

Each component's README describes its rollback procedure. General pattern:

1. Stop any services the component started.
2. Remove or rename the installed files.
3. Restore from any backup created during installation.
4. Restart your agent platform.

No component modifies another component's files. Rollbacks are isolated.

---

## Self-equipping

After setting up COFA, your agent may benefit from additional capabilities. These components point you toward relevant skills, plugins, and registries. That step is optional — the human and the agent decide what else to add based on their workload.

See individual component READMEs for pointers to relevant external resources.
