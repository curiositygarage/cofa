# COFA `solo` profile — the timed fast lane

The default profile is three components: long-term memory, policy-cel, continuity. This sheet is the
3-hour version of it: what a lane needs to be *useful to its owner today*, with everything else parked
in a phase-2 backlog the agent itself can finish later.

The rule that makes this honest: **a skipped gate is written down, never silently reclassified as
"partial".** A fast lane that lies about what it skipped is worse than a slow one, because the owner
cannot tell the difference until week two.

## T+0 — before anything installs (15 min)

- [ ] Owner intake answered, `spec.yaml` complete, `definition_of_done` filled
- [ ] Owner's model key and bot token supplied by the owner (never a builder's key)
- [ ] Owner's numeric Telegram id recorded in `spec.yaml` (`owner.telegram_id`)
- [ ] Host recon written: OS, interpreter (`py -0p` on Windows, not `where python`), free disk,
      ports in use, whether another agent already exists here

## T+15 — install and identity (45 min)

- [ ] Harness installed with the official installer; `--version` returns a version
- [ ] Every path resolves inside the folder the owner allowed (Windows: `-ShowResolvedPaths -Json`)
- [ ] `SOUL.md` / `AGENTS.md` / `USER.md` deployed from the owner's own words
- [ ] Identity files contain no third-party trace (no builder, no sibling, no peer lane)

## T+60 — memory and continuity (45 min)

- [ ] `hermes memory setup`, provider active, own store, own namespace
- [ ] Write → search round trip returns the written fact
- [ ] Continuity config deployed; `checks/verify.sh` 13/13, including the `--phase DONE` close-out
- [ ] Restart drill: lane restarted, checkpoint resolved, and a NEW message gets a reply
- [ ] `skills/self-improving/` present with corrections / memory / heartbeat (the promotion loop)

## T+105 — guardrails and channel (45 min)

- [ ] Approvals on (`smart`), headless paths denied, destructive battery blocked AND benign battery allowed
- [ ] Telegram: owner's bot, `rich_messages: true`, `media_delivery_allow_dirs` a real list
- [ ] `TELEGRAM_ALLOWED_USERS` and `TELEGRAM_HOME_CHANNEL` are the OWNER's id, no operator id anywhere
- [ ] One real turn: a table renders, a file attaches, a clarify button taps
- [ ] `web.search_backend` names a backend

## T+150 — proof and handoff (30 min)

Every line here is a check the operator can run without extra tooling. If a check has no output, it did
not happen.

- [ ] Owner identity: the agent's allowed-users list and home channel both hold the OWNER's id, and no
      one else's id appears in either
- [ ] Credential isolation: no value in the agent's `.env` is byte-identical to a value the operator
      holds (compare hashes, never print the values)
- [ ] Provenance: no file, shell-history line, ssh artefact, cron comment or git author implies a third
      party set this up
- [ ] Every component's own `checks/verify.sh` passes, and `bin/scan-sanitisation.sh` reports clean on
      the tree about to be handed over
- [ ] Off-switch tested once and reversed
- [ ] Handoff runbook: what runs, where logs are, how to restart, how to remove

If the operator has a provisioning kit with its own gates, run those too. The checks above are the floor,
not the ceiling: they are the ones this package can prove on its own.

## Phase-2 backlog (the agent finishes these itself, in the owner's time)

- Browser lane + Stagehand (only if the job actually touches a portal)
- Voice notes / STT provider
- Owner acceptance week: five real tasks, no builder in the loop
- Cost alert threshold tuned to the owner's actual first bill
- Drift baseline re-hash at day 7 and day 30

Each backlog item is a line in the handoff doc with the gate that would close it. "Later" with no gate
is how a fast lane becomes a permanent one.
