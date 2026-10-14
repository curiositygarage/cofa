#!/usr/bin/env bash
# A2A Mesh Client — verification.
#
# Contract: exit 0 ONLY when this component actually works on this machine.
#   exit 0 = deployed config resolved AND a real send→receipt cycle succeeded
#   exit 1 = a check failed (each failure names what to fix)
#   exit 2 = usage / missing prerequisite
#
# Non-vacuity: phase 0 re-runs this script with an EMPTY config dir and requires it to FAIL.
# A verifier that cannot fail proves nothing — that was the defect this file replaces.
#
# Deployed config (written by the install step in README.md):
#   ${COFA_CONFIG_DIR:-$HOME/.config/cofa}/a2a-mesh/config.yaml
set -uo pipefail

# A checker must not perturb the artifact it inspects: importing a shipped module writes
# __pycache__/*.pyc into the component tree, and the no-mutation phase below would then
# (correctly) flag the checker's own side effect as an edit. Disable bytecode writing here
# rather than documenting an env var the operator has to remember.
export PYTHONDONTWRITEBYTECODE=1

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPONENT_DIR="$(cd "$SELF_DIR/.." && pwd)"
CLIENT="$COMPONENT_DIR/lib/a2a_client.py"
CONFIG_DIR="${COFA_CONFIG_DIR:-$HOME/.config/cofa}"
CONFIG="$CONFIG_DIR/a2a-mesh/config.yaml"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "=== A2A Mesh Client Verify ==="
echo "config: $CONFIG"

# ------------------------------------------------------------------ prerequisites
if ! command -v python3 >/dev/null 2>&1; then
  echo "REQUIREDCHECK python3: this component's client and verifier are Python 3.9+ scripts."
  exit 2
fi
if [ ! -f "$CLIENT" ]; then
  fail "client missing: $CLIENT"
  echo "Results: $PASS passed  $FAIL failed"
  exit 1
fi

# ------------------------------------------------------------------ phase 0: can it fail?
if [ "${COFA_VERIFY_SELFCHECK:-0}" != "1" ]; then
  EMPTY="$(mktemp -d)"
  COFA_CONFIG_DIR="$EMPTY" COFA_VERIFY_SELFCHECK=1 bash "$0" >"$TMP/selfcheck.log" 2>&1
  rc=$?
  rm -rf "$EMPTY"
  if [ "$rc" -ne 0 ]; then
    pass "self-check: verifier FAILS when the component is not deployed (exit $rc)"
  else
    fail "self-check: verifier PASSED with an empty config dir — it cannot fail, so it proves nothing"
  fi
fi

# ------------------------------------------------------------------ phase 1: client runs
# NOTE: py_compile.compile() writes __pycache__/*.pyc even when PYTHONDONTWRITEBYTECODE=1 is
# set (that variable governs the import machinery, not explicit compile() calls). Parsing the
# source proves the same thing — that it compiles — while leaving the tree untouched.
if python3 -B -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$CLIENT" 2>"$TMP/compile.err"; then
  pass "client compiles (python3 $(python3 -c 'import platform;print(platform.python_version())'))"
else
  fail "client does not compile: $(head -1 "$TMP/compile.err")"
fi

# ------------------------------------------------------------------ phase 2: deployed config
PEERS=""
if [ ! -f "$CONFIG" ]; then
  fail "no deployed config at $CONFIG — the component is not installed"
  echo "REQUIREDCHECK a2a-mesh-config: copy config.sample.yaml to $CONFIG and set my_agent_id + at least one peer endpoint."
elif python3 - "$CONFIG" "$CLIENT" >"$TMP/peers.txt" 2>"$TMP/cfg.err" <<'PY'
import importlib.util, sys

spec = importlib.util.spec_from_file_location("a2a_client", sys.argv[2])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
cfg = mod.load_config(sys.argv[1])

problems = []
agent = str(cfg.get("my_agent_id") or "")
if not agent or "<" in agent:
    problems.append(f"my_agent_id is unset or still a placeholder ({agent!r})")
try:
    timeout = float(cfg.get("timeout_ms", 0))
except (TypeError, ValueError):
    timeout = 0
if timeout <= 0:
    problems.append(f"timeout_ms must be a positive number (got {cfg.get('timeout_ms')!r})")
peers = cfg.get("peers") or {}
if not peers:
    problems.append("no peers configured")
for name, entry in peers.items():
    endpoint = entry.get("endpoint") if isinstance(entry, dict) else entry
    if not endpoint:
        problems.append(f"peer {name}: no endpoint")
        continue
    if "<" in str(endpoint) or ">" in str(endpoint):
        problems.append(f"peer {name}: endpoint still a placeholder ({endpoint})")
    elif not str(endpoint).startswith(("http://", "https://")):
        problems.append(f"peer {name}: endpoint must be an http(s) URL ({endpoint})")
    else:
        print(name)
if problems:
    print("PROBLEMS: " + "; ".join(problems), file=sys.stderr)
    sys.exit(1)
PY
then
  PEERS="$(paste -sd, "$TMP/peers.txt")"
  pass "deployed config is real: agent id set, ${PEERS//,/ } reachable peer(s) declared"
else
  fail "deployed config is unusable: $(tail -1 "$TMP/cfg.err")"
fi

# ------------------------------------------------------------------ phase 3: send → receipt
# A generated config + loopback receiver: the component's own artifact does the work.
cat > "$TMP/loop.yaml" <<'YAML'
my_agent_id: "verify-harness"
timeout_ms: 5000
peers:
  loopback:
    endpoint: "http://127.0.0.1:__PORT__/a2a"
    id: "verify-loopback"
YAML

start_receiver() { # $1=out-file $2=stall $3=record $4=requests(default 1) $5...=extra serve flags
  python3 "$CLIENT" serve --port 0 --record "$3" --requests "${4:-1}" --stall "$2" "${@:5}" >"$1" 2>&1 &
  RECV_PID=$!          # so a test can stop a receiver that is still listening
  local i
  for i in $(seq 1 60); do
    grep -q LISTENING "$1" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

if start_receiver "$TMP/serve.out" 0 "$TMP/recv.jsonl"; then
  PORT="$(awk '/LISTENING/{print $2}' "$TMP/serve.out")"
  # Portable in-place edit: macOS sed has no GNU-style -i (it would eat the next argument as a
  # backup suffix). Write beside, then move — this runs on a Mac in CI (external review).
  sed "s/__PORT__/$PORT/" "$TMP/loop.yaml" > "$TMP/loop.yaml.new" && mv "$TMP/loop.yaml.new" "$TMP/loop.yaml"
  if python3 "$CLIENT" send --config "$TMP/loop.yaml" --peer loopback --message "cofa verify ping" >"$TMP/send.out" 2>&1; then
    pass "send accepted: $(cat "$TMP/send.out")"
  else
    fail "send failed (exit $?): $(cat "$TMP/send.out")"
  fi
  wait 2>/dev/null
  if grep -q "cofa verify ping" "$TMP/recv.jsonl" 2>/dev/null; then
    pass "receiver recorded the task body — send→receipt cycle closed"
  else
    fail "receiver did not record the task (receipt: $(cat "$TMP/recv.jsonl" 2>/dev/null | tr '\n' ' '))"
  fi
  if grep -q '"method": "SendMessage"' "$TMP/recv.jsonl" 2>/dev/null; then
    pass "protocol: request carries the A2A v1.0 method name SendMessage"
  else
    fail "protocol: method was not SendMessage — receipt: $(tr '\n' ' ' < "$TMP/recv.jsonl" 2>/dev/null)"
  fi
  if grep -q '"sender": "verify-harness"' "$TMP/recv.jsonl" 2>/dev/null; then
    pass "identity: the sender came from the config (my_agent_id) with no --sender flag"
  else
    fail "identity: config my_agent_id did not reach the peer as message metadata"
  fi
else
  fail "loopback receiver did not start: $(cat "$TMP/serve.out" 2>/dev/null)"
fi

# ------------------------------------------------------------------ phase 3b: v1.0 envelope
# A compliant A2A v1.0 peer replies with a SendMessageResponse oneof — {"task": …} — not the bare
# Task that this component's own loopback returned above. A client that reads result["id"] directly
# sees nothing there and must NOT report ACCEPTED: ACCEPTED is the only evidence a caller gets that
# the task exists, so losing the task id silently is worse than failing loudly.
if start_receiver "$TMP/v1.out" 0 "$TMP/v1.jsonl" 1 --v1-response; then
  VPORT="$(awk '/LISTENING/{print $2}' "$TMP/v1.out")"
  if python3 "$CLIENT" send --endpoint "http://127.0.0.1:$VPORT/a2a" --message "cofa v1 envelope probe" >"$TMP/v1.send" 2>&1; then
    if grep -q 'task=task-' "$TMP/v1.send" && grep -q 'state=completed' "$TMP/v1.send"; then
      pass "v1.0 envelope: {\"task\": …} unwrapped — $(cat "$TMP/v1.send")"
    else
      fail "v1.0 envelope accepted but the task was not unwrapped: $(cat "$TMP/v1.send")"
    fi
  else
    fail "v1.0 envelope: client rejected a compliant SendMessageResponse (exit $?): $(cat "$TMP/v1.send")"
  fi
  wait 2>/dev/null
else
  fail "v1.0-envelope receiver did not start: $(cat "$TMP/v1.out" 2>/dev/null)"
fi

# The unwrap contract itself — including the unusable case, which must resolve to nothing rather
# than being waved through as ACCEPTED.
if python3 - "$CLIENT" >"$TMP/unwrap.out" 2>&1 <<'PY'
import importlib.util, sys

spec = importlib.util.spec_from_file_location("a2a_client", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

cases = [
    ({"task": {"id": "t-1", "status": {"state": "completed"}}}, "task", "t-1"),      # v1.0
    ({"id": "t-legacy", "status": {"state": "completed"}}, "task", "t-legacy"),      # pre-1.0
    ({"message": {"messageId": "m-1"}}, "message", "m-1"),                           # oneof sibling
    ({"unexpected": True}, "", ""),                                                  # unusable
]
for result, want_kind, want_id in cases:
    kind, obj = mod.unwrap_send_message_response(result)
    got = obj.get("id") or obj.get("messageId") or ""
    if kind != want_kind or (want_kind and got != want_id) or (not want_kind and obj):
        print(f"MISMATCH {result!r}: got ({kind!r}, {got!r}), want ({want_kind!r}, {want_id!r})")
        sys.exit(1)
print("ok")
PY
then
  pass "response envelope: v1.0 wrapper, legacy bare Task, message oneof, and unusable all resolve"
else
  fail "response envelope contract broken: $(tail -1 "$TMP/unwrap.out")"
fi

# ------------------------------------------------------------------ phase 3c: task state → exit code
# ACCEPTED is an allowlist. A denylist let every unlisted state — auth-required, input-required,
# TASK_STATE_UNSPECIFIED, an empty or missing state — exit 0 ACCEPTED for a task that was refused
# or paused on the caller, and a status that was not an object ({"status": "completed"}) crashed
# the client with an uncaught AttributeError instead of a reported exit code. Each case below is
# driven through the real send() against a canned peer, so the exit code is proven, not inferred.
if python3 - "$CLIENT" >"$TMP/states.out" 2>&1 <<'PY'
import importlib.util, json, sys, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

spec = importlib.util.spec_from_file_location("a2a_client", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

CASES = {
    "/completed":  ({"task": {"id": "t", "status": {"state": "completed"}}}, 0),
    "/enum-ok":    ({"task": {"id": "t", "status": {"state": "TASK_STATE_COMPLETED"}}}, 0),
    "/working":    ({"task": {"id": "t", "status": {"state": "WORKING"}}}, 0),
    "/rejected":   ({"task": {"id": "t", "status": {"state": "REJECTED"}}}, 5),
    "/enum-rej":   ({"task": {"id": "t", "status": {"state": "TASK_STATE_REJECTED"}}}, 5),
    "/canceled":   ({"task": {"id": "t", "status": {"state": "CANCELLED"}}}, 5),
    "/input-req":  ({"task": {"id": "t", "status": {"state": "input-required"}}}, 6),
    "/auth-req":   ({"task": {"id": "t", "status": {"state": "auth-required"}}}, 6),
    "/status-str": ({"task": {"id": "t", "status": "completed"}}, 4),
    "/no-status":  ({"task": {"id": "t"}}, 4),
    "/state-null": ({"task": {"id": "t", "status": {"state": None}}}, 4),
    "/unspec":     ({"task": {"id": "t", "status": {"state": "TASK_STATE_UNSPECIFIED"}}}, 4),
    "/bogus":      ({"task": {"id": "t", "status": {"state": "bogus-state"}}}, 4),
}


class H(BaseHTTPRequestHandler):
    def do_POST(self):
        entry = CASES.get(self.path)
        body = json.dumps({"jsonrpc": "2.0", "id": "1", "result": entry[0]} if entry else {}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        return


srv = HTTPServer(("127.0.0.1", 0), H)
port = srv.server_address[1]
threading.Thread(target=srv.serve_forever, daemon=True).start()

bad = 0
for path, (_result, want) in CASES.items():
    try:
        rc = mod.send(f"http://127.0.0.1:{port}{path}", "probe", timeout=5)
    except Exception as exc:
        rc = f"CRASH {type(exc).__name__}: {exc}"
    if rc != want:
        print(f"MISMATCH {path}: exit={rc!r}, want {want}")
        bad += 1
srv.shutdown()
if bad:
    sys.exit(1)
print(f"ok ({len(CASES)} state cases)")
PY
then
  pass "task state is an allowlist: completed/working accepted, terminal non-success 5, needs-action 6, unusable 4 ($(tail -1 "$TMP/states.out"))"
else
  fail "task-state mapping broken: $(tr '\n' ' ' < "$TMP/states.out")"
fi

# ------------------------------------------------------------------ phase 4: negative — refused
python3 "$CLIENT" send --endpoint "http://127.0.0.1:9/a2a" --message x --timeout 3 >"$TMP/refused.out" 2>&1
rc=$?
if [ "$rc" -eq 3 ] && grep -q REFUSED "$TMP/refused.out"; then
  pass "negative test: nothing listening → exit 3 REFUSED"
else
  fail "negative test: expected exit 3 REFUSED for a dead port, got exit $rc: $(cat "$TMP/refused.out")"
fi

# ------------------------------------------------------------------ phase 5: negative — timeout
if start_receiver "$TMP/stall.out" 6 "$TMP/stall.jsonl"; then
  SPORT="$(awk '/LISTENING/{print $2}' "$TMP/stall.out")"
  python3 "$CLIENT" send --endpoint "http://127.0.0.1:$SPORT/a2a" --message x --timeout 1 >"$TMP/timeout.out" 2>&1
  rc=$?
  wait 2>/dev/null
  if [ "$rc" -eq 3 ] && grep -q TIMEOUT "$TMP/timeout.out"; then
    pass "negative test: silent peer → exit 3 TIMEOUT (distinct from REFUSED)"
  else
    fail "negative test: expected exit 3 TIMEOUT, got exit $rc: $(cat "$TMP/timeout.out")"
  fi
else
  fail "stalling receiver did not start: $(cat "$TMP/stall.out" 2>/dev/null)"
fi

# ------------------------------------------------------------------ phase 5b: retry safety
# retry_attempts may fire ONLY when nothing was listening. A TIMEOUT can mean the peer is already
# working on the task; repeating it there would run the same work twice — the exact duplication
# the fallback ladder forbids. This asserts the retry count does not apply to timeouts.
if start_receiver "$TMP/retry.out" 2 "$TMP/retry.jsonl" 5; then
  RPORT="$(awk '/LISTENING/{print $2}' "$TMP/retry.out")"
  cat > "$TMP/retry.yaml" <<YAML
my_agent_id: "verify-harness"
timeout_ms: 1000
retry_attempts: 3
peers:
  loopback:
    endpoint: "http://127.0.0.1:$RPORT/a2a"
    id: "verify-loopback"
YAML
  python3 "$CLIENT" send --config "$TMP/retry.yaml" --peer loopback --message "cofa retry probe" >"$TMP/retry.send" 2>&1
  rc=$?
  sleep 5                     # a wrong retry would land in this window and be recorded
  n="$(grep -c 'cofa retry probe' "$TMP/retry.jsonl" 2>/dev/null || echo 0)"
  kill "$RECV_PID" 2>/dev/null
  wait 2>/dev/null
  if [ "$rc" -eq 3 ] && grep -q TIMEOUT "$TMP/retry.send" && [ "$n" -eq 1 ]; then
    pass "retry safety: a TIMEOUT was NOT retried — 1 delivery reached the peer, not 4"
  else
    fail "retry safety: expected exit 3 TIMEOUT with exactly 1 delivery, got exit $rc and $n delivery(ies)"
  fi
else
  fail "retry-safety receiver did not start"
fi

# ...and the same code must still retry when the port is dead, or the check above is vacuous.
cat > "$TMP/dead.yaml" <<'YAML'
my_agent_id: "verify-harness"
timeout_ms: 1000
retry_attempts: 2
peers:
  dead:
    endpoint: "http://127.0.0.1:9/a2a"
    id: "verify-dead"
YAML
python3 "$CLIENT" send --config "$TMP/dead.yaml" --peer dead --message x >"$TMP/deadretry.out" 2>&1
rc=$?
if [ "$rc" -eq 3 ] && [ "$(grep -c REFUSED "$TMP/deadretry.out")" -eq 3 ] && grep -q 'RETRY 1/2' "$TMP/deadretry.out"; then
  pass "retry non-vacuity: a dead port DID retry (3 attempts = 1 + 2 configured)"
else
  fail "retry path did not fire as configured (exit $rc): $(tr '\n' ' ' < "$TMP/deadretry.out")"
fi

# ------------------------------------------------------------------ phase 6: POST-only discipline
if start_receiver "$TMP/get.out" 0 "$TMP/get.jsonl"; then
  GPORT="$(awk '/LISTENING/{print $2}' "$TMP/get.out")"
  CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$GPORT/a2a" 2>/dev/null || echo 000)"
  wait 2>/dev/null
  if [ "$CODE" = "404" ]; then
    pass "GET probe returns 404 by design (POST-only discipline is real, not just documented)"
  else
    fail "GET probe returned $CODE — expected 404 (probe discipline broken)"
  fi
else
  fail "receiver for the GET probe did not start"
fi

# ------------------------------------------------------------------ summary
echo ""
echo "Results: $PASS passed  $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "STATUS: FAILED — a2a-mesh is NOT operational on this machine."
  exit 1
fi
echo "STATUS: PASSED — a2a-mesh client works and the deployment is real."
exit 0
