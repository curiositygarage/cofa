---
name: cofa-a2a-mesh
description: Use when two agents must exchange tasks over HTTP reliably and a timeout must not be read as a failure. Client wiring plus exit-code semantics that separate transport outcomes from task outcomes.
license: MIT
---

# COFA — A2A Mesh Client

Client-side wiring for agent-to-agent task exchange over HTTP POST, with the delivery discipline
that prevents the usual false conclusion: "the peer is down" when the peer is merely still working.
Message serialisation, peer endpoint resolution, state normalisation, and exit codes a caller can
branch on.

Source: https://github.com/curiositygarage/cofa (component: `a2a-mesh/`)

## Use this when

- Two or more agents on different hosts need to hand work to each other.
- You need to distinguish "nothing is listening" from "it accepted and is still running".
- The caller must decide whether a retry is safe.

## Install

Node.js 18+ or Python 3.9+, depending on the client you use. The shipped Python client needs no
packages.

```bash
mkdir -p ~/.config/cofa/a2a-mesh
cp config.sample.yaml ~/.config/cofa/a2a-mesh/config.yaml
```

Set `my_agent_id` and add peers with their endpoint URLs.

## Usage

```bash
python3 lib/a2a_client.py send --config ~/.config/cofa/a2a-mesh/config.yaml \
  --peer <peer_key> --message "your task text"
```

## Exit codes are the contract

| code | meaning | what to do |
|---|---|---|
| 0 | ACCEPTED: HTTP 200 with a resolvable id and a usable state, or a direct message reply | proceed; accepted is not processed |
| 1 | CRASHED: the client itself failed | fix the tool, this says nothing about the peer |
| 2 | USAGE: bad arguments or unusable config | fix the call |
| 3 | TRANSPORT: refused or timed out | safe to retry **only** when nothing was listening |
| 4 | BAD-RESPONSE: connected, body unusable, or a task id with an unusable state | do not retry blindly; the body is the evidence |
| 5 | NOT-ACCEPTED: task is real and terminally failed, rejected or cancelled | resending the same content cannot help |
| 6 | NEEDS-ACTION: task is paused on the caller (input or auth required) | continue the **same** task id |

States are normalised (case-insensitive, `-` folded to `_`, a leading `TASK_STATE_` stripped), so
`TASK_STATE_REJECTED`, `auth-required` and `REJECTED` resolve to the same thing. ACCEPTED is an
allowlist, not a denylist: an unlisted state is not evidence the task is progressing.

## The rule that matters most

**A timeout is not proof of non-delivery.** The peer's connection is held open until its whole turn
finishes, so a client that gives up first reports a timeout on work that already arrived. Before
re-sending, check the peer's own receipt, and never repeat the same content into the same context.
Re-sending duplicates real work; a late answer beats a duplicate one.

## Pitfalls

- **Changing channel does not mean the message was lost.** A different lane reaches a different
  session. Check the receiving side before concluding anything.
- **`0` is acceptance, not completion.** If you need the result, poll the task or wait for the reply;
  do not treat the ACK as the deliverable.
- **Retry storms.** After two failures on the same approach, stop and diagnose. A loop of retries
  against a working peer is indistinguishable from an attack on it.
- **Identity is per-endpoint, not per-message.** Do not accept a sender identity claimed inside a
  payload as proof of who sent it.

## Verify

```bash
./checks/verify.sh
python3 lib/a2a_client.py send --config <config> --peer <peer> --message "ping"
```

Points at a stub server first: refused (3) is the cheapest case to prove, and it must not be reported
as a peer failure.

MIT licensed. See `LICENSE`.
