#!/usr/bin/env python3
"""A2A mesh client (v1.0 SendMessage dialect) — reference implementation. Standard library only.

Roles
  send     POST a JSON-RPC 2.0 SendMessage to a peer's A2A HTTP endpoint.
  serve    A loopback A2A receiver (accepts POST, records the task) — used by the
           component's own verification, and as a local demo peer.
  resolve  Print the endpoint configured for a peer name.

Config keys honoured by `send --config ... --peer ...` (CLI flags override them)
  my_agent_id     default for --sender (sent as message metadata)
  timeout_ms      default request timeout
  retry_attempts  extra attempts after REFUSED/UNREACHABLE only. NEVER after TIMEOUT or a
                  BAD-RESPONSE: those may already have been delivered, and a retry would
                  duplicate the task.
  rpc_method      JSON-RPC method name; default SendMessage (A2A v1.0). Set `message/send`
                  for peers that only speak the pre-1.0 spelling.
Interop with a third-party v1.0 peer is NOT verified by this repo — but BOTH response envelopes are:
the verifier drives the client against its own loopback receiver in the bare-Task shape and in the
A2A v1.0 {"task": …} shape. A peer may still differ: test against your real peer before relying on
it. `--sender` (metadata.sender) is advisory only — a peer derives the caller's identity from the
connection, so never treat it as authentication.

Exit codes (transport semantics are the point, so they are explicit)
  0  ACCEPTED       HTTP 200, a parseable JSON-RPC result, a resolvable task/message id, and a task
                     state a caller can act on: SUBMITTED, WORKING or COMPLETED. Both envelope
                     shapes are accepted: the v1.0 SendMessageResponse ({"task": …} / {"message": …})
                     and a legacy bare Task. Accepted != processed: confirm receipt in the peer's
                     own store. ACCEPTED is an ALLOWLIST, not a denylist — an unlisted or unknown
                     state is not evidence that the task is progressing.
  4  BAD-RESPONSE   Connected, but the body is not a usable JSON-RPC reply — or the task id is real
                     and its state is unusable (unknown spelling, empty, missing, or a status that
                     is not an object). The task id is printed on stderr, so the caller can still
                     follow the task up out of band. Reported on STDERR: a caller parsing stdout
                     gets nothing for 4, 5 and 6.
  5  NOT-ACCEPTED   The task is real and in a TERMINAL NON-SUCCESS state: FAILED, REJECTED,
                     CANCELED, CANCELLED. Not BAD-RESPONSE — the identity is there — and
                     emphatically not ACCEPTED: printing a REJECTED task as ACCEPTED handed the
                     caller a success line for work that was refused. Reported on stderr, with the
                     task id. Resending the same content will not help.
  6  NEEDS-ACTION   The task is real and PAUSED ON THE CALLER: INPUT_REQUIRED or AUTH_REQUIRED.
                     Supply the input or the credentials and continue the SAME task id — resending
                     as a new task would duplicate the work. Reported on stderr, with the task id.
  3  TRANSPORT      REFUSED (nothing listening) or TIMEOUT (no reply in time).
                     A timeout is NOT proof of non-delivery — a gateway may hold the
                     response open for the peer's whole turn. Treat it as unknown.
  2  USAGE          Bad arguments or an unusable config.
  1  CRASHED        The client itself failed — a defect in THIS tool, not a transport outcome.
                     Report it with the traceback. Do not read it as a statement about the peer, and
                     do not retry it as though the peer had refused.

Codes 4, 5 and 6 are NEVER retried: resending the same content cannot change a REJECTED task, and
"no usable state" is not a transport failure. Only 3 (TRANSPORT/REFUSED) is safe to retry, and even
that only when nothing was listening.

Exit 6 asks the caller to continue the SAME task id, but this client only PRINTS the id: it has no
--task-id or --context-id to resume one, so continuing a paused task is an out-of-band step for the
caller today. That is a gap in this client, not a hidden capability.

A direct message reply — a peer that answers with a message and no task object — also exits 0.
ACCEPTED covers "the peer answered"; it does not assert that a task exists or is progressing.

State spellings: normalised case-insensitively, `-` folded to `_`, and a leading `TASK_STATE_`
stripped, so `TASK_STATE_REJECTED`, `auth-required` and `REJECTED` all resolve.
"""
from __future__ import annotations

import argparse
import json
import socket
import sys
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

EXIT_OK, EXIT_USAGE, EXIT_TRANSPORT, EXIT_BAD_RESPONSE, EXIT_NOT_ACCEPTED, EXIT_NEEDS_ACTION = (
    0, 2, 3, 4, 5, 6,
)
DEFAULT_TIMEOUT = 60.0
DEFAULT_METHOD = "SendMessage"   # A2A v1.0 spelling; pre-1.0 peers want message/send (config: rpc_method)
_last_failure = ""  # "refused" only when nothing was listening — the one case safe to retry

# A2A task states, split by what the CALLER does next. ACCEPTED is an allowlist: a state that is
# not in it is not evidence that the task exists and is progressing.
ACCEPT_STATES = frozenset({"SUBMITTED", "WORKING", "COMPLETED"})
TERMINAL_NON_SUCCESS = frozenset({"FAILED", "REJECTED", "CANCELED", "CANCELLED"})
NEEDS_ACTION_STATES = frozenset({"INPUT_REQUIRED", "AUTH_REQUIRED"})


def state_of(status: object) -> tuple[str | None, str]:
    """``(normalised_state, display)`` for the peer-controlled ``status`` field of a Task.

    ``status`` is ``{"state": "..."}`` on a compliant peer, but it is peer-controlled data: a bare
    string, an int or a list is syntactically valid JSON, and reading ``.get`` on it raised
    AttributeError inside ``send()`` — the client died with an uncaught traceback (exit 1) instead
    of reporting an exit code. Same defect class as a non-string id, so it gets the same treatment:
    anything that is not the expected shape resolves to "no usable state".

    Normalisation takes the spellings real peers use: ``TASK_STATE_REJECTED`` (v0.3 enum names),
    ``auth-required`` / ``input-required`` (kebab, lowercase) and bare ``REJECTED`` all resolve.
    """
    if not isinstance(status, dict):
        return None, "no status field" if status is None else f"status is not an object ({type(status).__name__})"
    raw = status.get("state")
    if raw is None:
        return None, "no state field"
    if not isinstance(raw, str):
        return None, f"state is not a string ({type(raw).__name__})"
    if not raw.strip():
        return None, "state is blank"
    norm = raw.strip().upper().replace("-", "_")
    if norm.startswith("TASK_STATE_"):
        norm = norm[len("TASK_STATE_"):]
    return (norm or None), raw


# --------------------------------------------------------------------------- config
def _minimal_yaml(text: str) -> dict:
    """Parse the shipped config shape without PyYAML (flat scalars + one nested map).

    Deliberately narrow: it understands exactly what config.sample.yaml documents
    (``key: value`` at indent 0, and one level of nesting, e.g. ``peers: peer_a: endpoint:``).
    """
    root: dict = {}
    parent: dict | None = None
    for raw in text.splitlines():
        line = raw.split(" #")[0].rstrip()
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(line) - len(line.lstrip())
        key, _, value = stripped.partition(":")
        value = value.strip().strip('"').strip("'")
        if indent == 0:
            if value:
                root[key] = value
                parent = None
            else:
                root[key] = {}
                parent = root[key]
        elif parent is not None:
            if value:
                parent[key] = value
            else:
                parent[key] = {}
                parent = parent[key]
    return root


def load_config(path: str) -> dict:
    from pathlib import Path

    text = Path(path).read_text()
    try:
        import yaml  # optional; richer configs are fine when it is present

        return yaml.safe_load(text) or {}
    except ImportError:
        return _minimal_yaml(text)


def resolve_endpoint(config: dict, peer: str) -> str:
    peers = config.get("peers") or {}
    entry = peers.get(peer)
    if entry is None:
        raise KeyError(f"peer {peer!r} not in config (have: {', '.join(sorted(peers)) or 'none'})")
    endpoint = entry.get("endpoint") if isinstance(entry, dict) else entry
    if not endpoint:
        raise KeyError(f"peer {peer!r} has no endpoint")
    return str(endpoint)


# --------------------------------------------------------------------------- send
def build_request(message: str, sender: str | None = None, request_id: str | None = None,
                  method: str = DEFAULT_METHOD) -> dict:
    rid = request_id or f"req-{int(time.time() * 1000)}"
    msg = {"role": "user", "messageId": rid, "parts": [{"kind": "text", "text": message}]}
    if sender:
        msg["metadata"] = {"sender": sender}
    return {"jsonrpc": "2.0", "id": rid, "method": method, "params": {"message": msg}}


def _q(value: object, limit: int = 200) -> str:
    """Peer-controlled text, rendered safe for a terminal and for whatever reads the output.

    The exit code can be right while the LINE is forged: a newline in a task id, a state or a
    messageId ends the record early and starts a second one — ``ACCEPTED: HTTP 200 task=evil``
    on stdout, or a NOT-ACCEPTED line on stderr — and an ANSI escape in a state rewrites the
    terminal. repr-escaping turns a newline into ``\\n`` and an escape into ``\\x1b``, so a value
    can never break its own line. ``ascii()`` also escapes every non-ASCII character (ü prints
    as ``\\xfc``), which is ugly but unambiguous; swap it for a non-printable-only escape if the
    ugliness ever matters. The cap applies after escaping, so the escaped form is never truncated
    mid-escape.
    """
    return ascii(str(value))[1:-1][:limit]


def unwrap_send_message_response(result: object) -> tuple[str, dict]:
    """A2A v1.0 SendMessageResponse is a oneof of ``task`` / ``message``; legacy peers
    return the Task or the Message bare. Returns ``(kind, payload)`` with kind ``task`` /
    ``message`` / ``""`` (unusable). A caller that reads ``result["id"]`` directly sees
    nothing against a v1.0 peer — the wrapper must be unwrapped, and a result with no
    resolvable id is not receipt evidence.

    A pre-1.0 peer may reply with a bare Message (``messageId``, no ``id``): that reply does
    carry an identity, so it is accepted as ``message`` — keyed on ``messageId``, not ``id``.
    """
    def _ident(value):
        # An identity is a NON-EMPTY, PRINTABLE STRING and nothing else. Accepting any truthy value
        # let an int or a dict through as an id, and reading either field on either envelope let
        # {"task": {"messageId": "m"}} pass as a task — the caller then read obj["id"] and died
        # with an uncaught KeyError (exit 1) instead of reporting BAD-RESPONSE (exit 4). A
        # whitespace-only id and a newline-bearing id are equally unusable: the first is not an
        # identity at all, and the second forges a line the moment it is printed.
        return value if isinstance(value, str) and value.strip() and value.isprintable() else None

    if isinstance(result, dict):
        # Each envelope key is held to ITS OWN identity field: a task is identified by `id`, a
        # message by `messageId`. The other field, on the wrong envelope, is not an identity.
        inner = result.get("task")
        if isinstance(inner, dict) and _ident(inner.get("id")):
            return "task", inner
        inner = result.get("message")
        if isinstance(inner, dict) and _ident(inner.get("messageId")):
            return "message", inner
        if _ident(result.get("id")):
            return "task", result          # legacy: bare Task as the result
        if _ident(result.get("messageId")):
            return "message", result       # pre-1.0 bare Message: identity lives in messageId
    return "", {}


def send(endpoint: str, message: str, *, sender: str | None = None, timeout: float = DEFAULT_TIMEOUT,
         method: str = DEFAULT_METHOD) -> int:
    global _last_failure
    _last_failure = ""  # reset per attempt: a stale "refused" must never license a retry after a timeout
    body = json.dumps(build_request(message, sender, method=method)).encode()
    req = urllib.request.Request(
        endpoint, data=body, method="POST", headers={"Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            status, raw = resp.status, resp.read()
    except urllib.error.HTTPError as exc:
        detail = exc.read()[:300].decode("utf-8", "replace")
        print(f"BAD-RESPONSE: HTTP {exc.code} from {endpoint}: {_q(detail)}", file=sys.stderr)
        return EXIT_BAD_RESPONSE
    except urllib.error.URLError as exc:
        reason = exc.reason
        if isinstance(reason, (TimeoutError, socket.timeout)):
            print(f"TIMEOUT: no reply from {endpoint} within {timeout}s (NOT proof of non-delivery)", file=sys.stderr)
            return EXIT_TRANSPORT
        if isinstance(reason, ConnectionRefusedError):
            _last_failure = "refused"
            print(f"REFUSED: nothing listening at {endpoint}", file=sys.stderr)
            return EXIT_TRANSPORT
        print(f"UNREACHABLE: {endpoint}: {reason}", file=sys.stderr)
        return EXIT_TRANSPORT
    except (TimeoutError, socket.timeout):
        print(f"TIMEOUT: no reply from {endpoint} within {timeout}s (NOT proof of non-delivery)", file=sys.stderr)
        return EXIT_TRANSPORT
    except OSError as exc:
        print(f"UNREACHABLE: {endpoint}: {exc}", file=sys.stderr)
        return EXIT_TRANSPORT

    try:
        payload = json.loads(raw.decode("utf-8", "replace"))
    except ValueError:
        print(f"BAD-RESPONSE: HTTP {status} but the body is not JSON", file=sys.stderr)
        return EXIT_BAD_RESPONSE
    if isinstance(payload, dict) and payload.get("error"):
        print(f"BAD-RESPONSE: peer returned an error: {_q(payload['error'])}", file=sys.stderr)
        return EXIT_BAD_RESPONSE
    if not isinstance(payload, dict) or "result" not in payload:
        print(f"BAD-RESPONSE: no JSON-RPC result in {_q(payload)}", file=sys.stderr)
        return EXIT_BAD_RESPONSE

    kind, obj = unwrap_send_message_response(payload["result"])
    if kind == "task":
        task_id = obj.get("id")
        state, shown = state_of(obj.get("status"))
        # ACCEPTED is an ALLOWLIST. It is the only evidence a caller gets that the task exists and
        # is progressing, and a denylist let every unlisted spelling through: auth-required,
        # input-required, TASK_STATE_UNSPECIFIED, an empty state, a state of None. Each of those
        # returned 0 ACCEPTED for a task that was refused, paused, or malformed.
        # Every peer-controlled value below goes through _q(): the id and the state are the peer's
        # strings, and a newline in either would forge a whole extra line of stdout or stderr.
        if state in ACCEPT_STATES:
            print(f"ACCEPTED: HTTP {status} task={_q(task_id)} state={_q(shown)}")
            return EXIT_OK
        if state in TERMINAL_NON_SUCCESS:
            print(f"NOT-ACCEPTED: HTTP {status} task={_q(task_id)} state={_q(shown)} — the peer holds the "
                  f"task and did not accept it", file=sys.stderr)
            return EXIT_NOT_ACCEPTED
        if state in NEEDS_ACTION_STATES:
            print(f"NEEDS-ACTION: HTTP {status} task={_q(task_id)} state={_q(shown)} — the task is paused "
                  f"on the caller: supply the input or the credentials and continue the SAME "
                  f"task id (resending as a new task would duplicate it)", file=sys.stderr)
            return EXIT_NEEDS_ACTION
        # A real task id with a state no client can act on. Not ACCEPTED (the state proves
        # nothing) and not NOT-ACCEPTED (the peer may yet work on it) — the id is printed so the
        # caller can follow it up out of band.
        print(f"BAD-RESPONSE: HTTP {status} task={_q(task_id)} carries no usable state — {_q(shown)}",
              file=sys.stderr)
        return EXIT_BAD_RESPONSE
    elif kind == "message":
        print(f"ACCEPTED: HTTP {status} message={_q(obj.get('messageId'))} (peer answered without a task)")
    else:
        # The v1.0 envelope is {"task": …} / {"message": …}; reading result["id"] directly sees
        # nothing against a compliant peer. Reporting ACCEPTED there would hide the loss of
        # identity — and ACCEPTED is the only evidence a caller has that the task exists.
        print(f"BAD-RESPONSE: JSON-RPC result carries no task or message id: {_q(payload['result'])}",
              file=sys.stderr)
        return EXIT_BAD_RESPONSE
    return EXIT_OK


# --------------------------------------------------------------------------- serve
def _record(path: str, entry: dict) -> None:
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(entry) + "\n")


def serve(port: int, record_path: str, requests: int, stall: float, v1_response: bool = False) -> int:
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_GET(self):  # POST-only by design: a GET is a probe, not dispatch
            self.send_error(404, "A2A endpoints are POST-only by design")

        def do_POST(self):
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length)
            try:
                payload = json.loads(raw.decode("utf-8", "replace"))
            except ValueError:
                payload = {"_unparsed": raw[:200].decode("utf-8", "replace")}
            rid = payload.get("id") if isinstance(payload, dict) else None
            text, sender, method = "", None, None
            params = payload.get("params") if isinstance(payload, dict) else None
            if isinstance(payload, dict):
                method = payload.get("method")
            if isinstance(params, dict):
                msg = params.get("message") or {}
                text = "".join(p.get("text", "") for p in (msg.get("parts") or []) if isinstance(p, dict))
                sender = (msg.get("metadata") or {}).get("sender")
            _record(record_path, {"received_at": time.time(), "id": rid, "text": text, "path": self.path,
                                  "method": method, "sender": sender})
            if stall:
                time.sleep(stall)
            task = {"id": f"task-{int(time.time() * 1000)}", "status": {"state": "completed"}}
            # A2A v1.0 wraps the Task in a SendMessageResponse oneof; older peers return it bare.
            resp = json.dumps({"jsonrpc": "2.0", "id": rid,
                               "result": {"task": task} if v1_response else task}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(resp)))
            self.end_headers()
            self.wfile.write(resp)

        def log_message(self, *args):  # keep verification output readable
            pass

    # Single-threaded on purpose: handle_request() must BLOCK until the reply is written,
    # otherwise the socket closes under the caller (a threaded server returns immediately).
    srv = HTTPServer(("127.0.0.1", port), Handler)
    print(f"LISTENING {srv.server_address[1]}", flush=True)
    try:
        for _ in range(max(1, requests)):
            srv.handle_request()
    finally:
        srv.server_close()
    return EXIT_OK


# --------------------------------------------------------------------------- cli
def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="a2a_client.py", description="A2A mesh client (v1.0 SendMessage dialect, stdlib only)")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_send = sub.add_parser("send", help="send one A2A task")
    p_send.add_argument("--endpoint")
    p_send.add_argument("--config")
    p_send.add_argument("--peer")
    p_send.add_argument("--message", required=True)
    p_send.add_argument("--sender", default=None)
    p_send.add_argument("--timeout", type=float, default=None,
                        help="seconds; default from config timeout_ms, else 60")

    p_serve = sub.add_parser("serve", help="run a loopback A2A receiver")
    p_serve.add_argument("--port", type=int, default=0)
    p_serve.add_argument("--record", required=True)
    p_serve.add_argument("--requests", type=int, default=1)
    p_serve.add_argument("--stall", type=float, default=0.0, help="delay each reply (timeout testing)")
    p_serve.add_argument("--v1-response", action="store_true",
                         help="reply with the A2A v1.0 SendMessageResponse envelope ({'task': …}); "
                              "without it the reply is a bare Task (pre-1.0 shape)")

    p_res = sub.add_parser("resolve", help="print a peer endpoint from config")
    p_res.add_argument("--config", required=True)
    p_res.add_argument("--peer", required=True)

    args = parser.parse_args(argv)

    if args.cmd == "serve":
        return serve(args.port, args.record, args.requests, args.stall, args.v1_response)

    if args.cmd == "resolve":
        try:
            print(resolve_endpoint(load_config(args.config), args.peer))
        except Exception as exc:
            print(f"USAGE: {exc}", file=sys.stderr)
            return EXIT_USAGE
        return EXIT_OK

    cfg: dict = {}
    if args.config:
        try:
            cfg = load_config(args.config)
        except OSError as exc:
            print(f"USAGE: {exc}", file=sys.stderr)
            return EXIT_USAGE
    endpoint = args.endpoint
    if not endpoint:
        if not (args.config and args.peer):
            print("USAGE: send needs --endpoint, or --config with --peer", file=sys.stderr)
            return EXIT_USAGE
        try:
            endpoint = resolve_endpoint(cfg, args.peer)
        except Exception as exc:
            print(f"USAGE: {exc}", file=sys.stderr)
            return EXIT_USAGE

    sender = args.sender or (str(cfg["my_agent_id"]) if cfg.get("my_agent_id") else None)
    timeout = args.timeout
    if timeout is None:
        try:
            timeout = float(cfg["timeout_ms"]) / 1000.0 if cfg.get("timeout_ms") else DEFAULT_TIMEOUT
        except (TypeError, ValueError):
            print(f"USAGE: timeout_ms must be a number (got {cfg.get('timeout_ms')!r})", file=sys.stderr)
            return EXIT_USAGE
    try:
        retries = max(0, int(cfg.get("retry_attempts") or 0))
    except (TypeError, ValueError):
        retries = 0
    method = str(cfg.get("rpc_method") or DEFAULT_METHOD)

    rc = send(endpoint, args.message, sender=sender, timeout=timeout, method=method)
    for attempt in range(retries):
        # Only a REFUSED connection is safe to repeat: nothing was listening, so nothing was
        # delivered. TIMEOUT and BAD-RESPONSE may already have been processed by the peer.
        if rc != EXIT_TRANSPORT or _last_failure != "refused":
            break
        time.sleep(min(2 ** attempt, 5))
        print(f"RETRY {attempt + 1}/{retries}: nothing was listening, nothing was delivered", file=sys.stderr)
        rc = send(endpoint, args.message, sender=sender, timeout=timeout, method=method)
    return rc


if __name__ == "__main__":
    sys.exit(main())
