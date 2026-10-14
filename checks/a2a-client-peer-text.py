#!/usr/bin/env python3
"""Exit-code AND output-integrity probe for ``a2a_client.send()``.

The exit code can be right while the LINE is forged. ``send()`` prints peer-controlled text —
the task id, the state, the messageId, the error body — so a newline in any of them ends the
record early and starts a second one (``ACCEPTED: HTTP 200 task=evil``), and an ANSI escape in
a state rewrites the terminal. A caller that greps the output is then reading the peer's text,
not the client's.

This probe stubs ``urlopen`` (no socket, no peer needed) and asserts, per case, that:

  * the exit code is the one the exit-code mapping promises, and
  * no peer-controlled value can add a line: stdout and stderr each stay within the number of
    lines the client is allowed to write, and control characters appear ONLY escaped.

  usage:  checks/a2a-client-peer-text.py [path/to/a2a-mesh/lib/a2a_client.py]
"""
import contextlib
import io
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_LIB = os.path.join(HERE, "..", "a2a-mesh", "lib")
lib = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_LIB
sys.path.insert(0, lib)
import a2a_client as C  # noqa: E402


class _Resp:
    def __init__(self, status, body):
        self.status, self._body = status, body

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def run(result, status=200):
    body = json.dumps({"jsonrpc": "2.0", "id": "1", "result": result}).encode()
    C.urllib.request.urlopen = lambda req, timeout=None: _Resp(status, body)
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        rc = C.send("http://peer.invalid/a2a", "hello")
    return rc, out.getvalue(), err.getvalue()


CASES = [
    # name                          result                                                          rc
    ("task completed",             {"task": {"id": "t1", "status": {"state": "TASK_STATE_COMPLETED"}}}, 0),
    ("task working",               {"task": {"id": "t1", "status": {"state": "working"}}},              0),
    ("task rejected",              {"task": {"id": "t1", "status": {"state": "REJECTED"}}},             5),
    ("task failed",                {"task": {"id": "t1", "status": {"state": "FAILED"}}},               5),
    ("task canceled (one l)",      {"task": {"id": "t1", "status": {"state": "canceled"}}},             5),
    ("task auth-required",         {"task": {"id": "t1", "status": {"state": "auth-required"}}},        6),
    ("task input-required",        {"task": {"id": "t1", "status": {"state": "INPUT_REQUIRED"}}},       6),
    ("task unspecified",           {"task": {"id": "t1", "status": {"state": "UNSPECIFIED"}}},          4),
    ("task blank state",           {"task": {"id": "t1", "status": {"state": "   "}}},                  4),
    ("task state is an int",       {"task": {"id": "t1", "status": {"state": 7}}},                      4),
    ("task status is None",        {"task": {"id": "t1", "status": None}},                              4),
    ("task status is a string",    {"task": {"id": "t1", "status": "completed"}},                       4),
    ("no id at all",               {"task": {"status": {"state": "completed"}}},                        4),
    ("bare message",               {"message": {"messageId": "m1"}},                                    0),
    ("id is an int",               {"task": {"id": 12, "status": {"state": "completed"}}},              4),
    # --- peer-controlled text must not be able to forge a line or emit a raw escape
    ("id carries a NEWLINE",       {"task": {"id": "t1\nACCEPTED: HTTP 200 task=evil",
                                             "status": {"state": "completed"}}},                        4),
    ("id is whitespace only",      {"task": {"id": "   ", "status": {"state": "completed"}}},           4),
    ("id carries an ESCAPE",       {"task": {"id": "t1\x1b[2J", "status": {"state": "completed"}}},     4),
    ("state carries a NEWLINE",    {"task": {"id": "t1", "status": {"state": "WORKING\nACCEPTED: x"}}}, 4),
    # A newline-bearing messageId is not a usable identity either, so the envelope is refused (4)
    # rather than accepted with an escaped value — the same rule the id follows.
    ("messageId newline",          {"message": {"messageId": "m1\nACCEPTED: HTTP 200 task=evil"}},      4),
]

BAD = 0
for name, result, want in CASES:
    rc, out, err = run(result)
    problems = []
    if rc != want:
        problems.append("exit %d, wanted %d" % (rc, want))
    # The client writes at most ONE line per stream for any of these results. More than one means
    # a peer-controlled value ended the record early and forged the next one.
    for stream, text in (("stdout", out), ("stderr", err)):
        lines = [ln for ln in text.split("\n") if ln]
        if len(lines) > 1:
            problems.append("%s forged a second line: %r" % (stream, text))
        if "\x1b" in text:
            problems.append("%s carries a raw ESCAPE" % stream)
    if problems:
        BAD += 1
        print("FAIL  %-26s %s" % (name, "; ".join(problems)))
    else:
        print("ok    %-26s exit %d  %s" % (name, rc, " ".join(out.split()) or " ".join(err.split())))

print()
print("peer-text problems: %d" % BAD)
if BAD:
    print("CLIENT-PEER-TEXT: FAILED — the exit code can be right while the printed line is the peer's")
else:
    print("CLIENT-PEER-TEXT: PASSED")
sys.exit(1 if BAD else 0)
