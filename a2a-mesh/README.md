# A2A Mesh Client Component

**A2A-style JSON-RPC client wiring (v1.0 `SendMessage` dialect)** — pre-1.0 message shape, v1.0 method name. Structured agent-to-agent task exchange over HTTP POST. Includes the proven probe discipline that prevents false-negative diagnoses.

---

## What it does

Provides the client-side wiring for A2A-style communication between agents (v1.0 `SendMessage` dialect; pre-1.0 message shape). Handles message serialization, peer endpoint resolution, error classification (timeout vs. actual failure), and the delivery verification protocol.

Two agents can exchange a task reliably once this is wired up. The acceptance criterion is: agent A sends a POST to agent B's A2A endpoint, B processes it, and A receives confirmation (directly or via a ping-back).

---

## Install

### Prerequisites

- **Node.js 18+** or **Python 3.9+**, depending on the client implementation you choose.
- Access to at least one peer's A2A endpoint (resolved from your platform's peer list).

### Steps

1. Copy the sample config:

```bash
mkdir -p ~/.config/cofa/a2a-mesh
cp config.sample.yaml ~/.config/cofa/a2a-mesh/config.yaml
```

2. Edit `~/.config/cofa/a2a-mesh/config.yaml`:
   - Set `my_agent_id` to your agent's identity string.
   - Add peers under `peers:` with their A2A endpoint URLs. Use placeholders like `http://<host>:<port>/a2a` until you resolve real endpoints from your platform's peer discovery mechanism.

3. Send a task with the shipped client (no package install needed):

```bash
python3 lib/a2a_client.py send --config ~/.config/cofa/a2a-mesh/config.yaml \
  --peer peer_a --message "your task text"
# ACCEPTED: HTTP 200 task=... state=...
```

   Exit codes carry the transport meaning, so a caller can branch on them:

   | 0 `ACCEPTED` | HTTP 200, a resolvable task/message id, and a state a caller can act on: `SUBMITTED`, `WORKING` or `COMPLETED`. A **direct message reply** — a peer that answers with a message and no task object — also exits 0: ACCEPTED covers "the peer answered", it does not assert that a task exists or is progressing. Accepted ≠ processed — confirm receipt in the peer's own store. |
   | 1 `CRASHED` | the client itself failed — a defect in this tool, not a transport outcome. Report it with the traceback; do not read it as a statement about the peer. |
   | 2 `USAGE` | bad arguments or an unusable config |
   | 3 `TRANSPORT` | `REFUSED` (nothing listening) or `TIMEOUT` (no reply in time). A timeout is not proof of non-delivery. |
   | 4 `BAD-RESPONSE` | connected, but the body is not a usable JSON-RPC reply — or the task id is real and its state is unusable (unknown spelling, empty, missing, or a `status` that is not an object). The task id is printed. |
   | 5 `NOT-ACCEPTED` | the task is real and terminal non-success: `FAILED`, `REJECTED`, `CANCELED`, `CANCELLED`. Resending the same content will not help. |
   | 6 `NEEDS-ACTION` | the task is real and paused **on the caller**: `INPUT_REQUIRED`, `AUTH_REQUIRED`. Supply the input or credentials and continue the **same task id** — resending as a new task would duplicate the work. |

   States are normalised (case-insensitive, `-` folded to `_`, a leading `TASK_STATE_` stripped), so
   `TASK_STATE_REJECTED`, `auth-required` and `REJECTED` all resolve. `ACCEPTED` is an allowlist, not
   a denylist: an unlisted state is not evidence that the task is progressing, and exit 0 is the only
   evidence a caller gets. Codes 4, 5 and 6 print to stderr — a caller parsing stdout gets nothing
   for them, by design — and they are **never retried**: resending the same content cannot change a
   `REJECTED` task, and "no usable state" is not a transport failure. Only 3 `TRANSPORT`/`REFUSED` is
   safe to retry, and only when nothing was listening. Wire the outbound side into your platform's
   messaging layer — if there is no hook API, a wrapper around your task sender is enough.

   Exit 6 asks the caller to act, so be precise about what this client gives you: it **prints** the
   task id (codes 4 and 6 write to stderr) but has no flag to resume one, so continuing a paused
   task is an out-of-band step for the caller. That is a gap in the client, not a hidden
   capability — do not build a caller that assumes otherwise.

4. Verify the connection:

```bash
./checks/verify.sh
```

### Configuration reference

See `config.sample.yaml` for every supported field. Key fields:

- `my_agent_id`: Your agent's identity string (sent in all outbound messages)
- `timeout_ms`: HTTP request timeout in milliseconds
- `retry_attempts`: Number of retries on transient failures
- `peers`: Map of peer agent IDs to their A2A endpoint URLs
- `--sender` / `metadata.sender`: an **advisory, self-asserted label — not authentication.** A peer
  derives the caller's identity from the connection (its client IP), never from this field, so it
  must not be treated as a credential. See `SECURITY.md`.

---

## The POST-only probe rule (critical)

**Treat a `GET` to an A2A RPC endpoint as meaningless.** Many gateways route only `POST` on the RPC path, so a `GET` returns 404 or 405 while the service is running and healthy. Assuming the RPC path must answer `GET` has caused two documented false diagnoses of "dead ports".

When diagnosing whether an A2A port is alive:

1. **Check the listener is present:** `ss -ltnp | grep <port>` or `netstat -tlnp | grep <port>`
2. **Send a POST probe** (not a GET): `curl -s -o /dev/null -w "%{http_code}" -X POST http://<host>:<port>/a2a -H "Content-Type: application/json" -d '{"jsonrpc":"2.0","id":1,"method":"message/send","params":{"message":{"role":"user","parts":[{"kind":"text","text":"probe"}]}}}'`

Do not call a port dead based on a `GET` 404 or 405 response — all it tells you is that the RPC path does not answer `GET`.

**Why this rule exists:** on an A2A-style layout, discovery and dispatch do not share a path. An agent’s public Agent Card is conventionally served as a `GET` at `/.well-known/agent-card.json`, while the RPC path takes `POST`. Probing the RPC path with `GET` conflates the two, so its failure carries no information about service health.

---

## Delivery verification protocol

After sending a message:

1. **HTTP 200 + result ID** means the receiving platform accepted the message — but it does NOT mean the peer processed it.
2. **Verify receipt** in the peer's own inbound message store or session log. An *accepted* message is not a *consumed* one.
3. **Timeout ≠ non-delivery.** The gateway holds the HTTP response open through the peer's entire turn. A reported timeout usually means the peer is still working, not that the message failed.

If a message stays unresolved, retry in this order:
1. Re-send with the existing context → 2. Re-send in a fresh session context → 3. Use the peer's own direct-message channel (whatever their platform provides) → 4. Fall back to a durable file drop that the peer's platform documents. Use only channels your own deployment actually has.

---

## Acceptance criterion

Two agents successfully exchange a task: agent A sends a well-formed A2A message to agent B's endpoint, and B's session log contains the incoming message with identifiable content. Record successful exchanges in your platform's notes file.

---

## Verify

Run `./checks/verify.sh`. It is not a documentation linter — it starts a loopback receiver and
checks the client's real behaviour:

- the client compiles and parses the deployed config (placeholder endpoints fail)
- a real `send` reaches a local receiver and the task body is recorded — the send→receipt cycle closes
- **envelopes:** the reply is unwrapped in every shape a peer may use — the A2A v1.0
  `SendMessageResponse` (`{"task": …}` or the `{"message": …}` oneof, keyed on `id` or
  `messageId`), a legacy bare Task, and a **pre-1.0 bare Message** (which carries `messageId`
  and no `id` — a reply that *does* carry an identity, so it is accepted rather than rejected) —
  and a result carrying neither id is reported as `BAD-RESPONSE` (exit 4), never as
  `ACCEPTED`. `ACCEPTED` is the only evidence a caller gets that the task exists, so losing the
  id silently is the worse failure.
  Run the receiver yourself with the v1.0 shape via `serve --record <file> --v1-response`.
- **provenance of the v1.0 reply we test against:** it is produced by the **shipped loopback
  receiver**, not captured from a third-party peer. That makes it a valid regression fixture
  (key order, separators, lowercase `status.state`, the `task-<epoch-ms>` id format all match a
  real v1.0 reply) but not an interoperability proof. A body captured from an independent
  implementation would be the stronger evidence and is not in this repo.
- **task state → exit code:** 13 canned peer replies drive the real `send()`, proving exit 0 only for
  `SUBMITTED`/`WORKING`/`COMPLETED`, 5 for terminal non-success, 6 for a task paused on the caller,
  and 4 for a real task id with an unknown, empty, missing or non-string state
- **negative:** a dead port returns exit 3 `REFUSED`
- **negative:** a peer that accepts but never answers returns exit 3 `TIMEOUT`, distinct from `REFUSED`
- a `GET` to an A2A endpoint returns 404 by design, proving the POST-only discipline rather than
  just documenting it
- the verifier re-runs itself with an empty config dir and requires that run to FAIL

Exit code 0 = the client works and the deployment is real. Non-zero = which check failed is printed.

---

## Limits

- **Third-party peers are untested.** The verifier exercises the shipped loopback receiver in both
  reply shapes it knows (the A2A v1.0 `{"task": …}` envelope and a legacy bare Task). It has not
  been run against an independent A2A v1.0 implementation, so a peer replying in some third shape
  gets `BAD-RESPONSE` rather than a guess.
- **The `result.message` oneof has a fixture, but only of our own making** — it is exercised by the
  unwrap contract in `checks/verify.sh`, and (like the `task` shape) the fixture is the shipped
  loopback receiver's output, not a capture from an independent implementation.
- **No retry after a parsed-but-unusable reply.** A `BAD-RESPONSE` can mean the task *was* already
  delivered, so retrying could duplicate it; only a refused connection is retried.
- **`metadata.sender` is not authentication** (see above).
- **Delivery verification is the caller's job.** `ACCEPTED` proves the peer accepted the task, not
  that the work happened; confirm the result in the peer's own artifact.

---

## Rollback

1. Stop the A2A sender/receiver in your platform configuration.
2. Remove the config: `rm -rf ~/.config/cofa/a2a-mesh/`
3. Restart your agent platform.

Removing this component does not affect other components.
