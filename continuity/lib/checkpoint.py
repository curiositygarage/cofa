#!/usr/bin/env python3
"""Continuity — checkpoint and resume. Standard library only.

The file is the contract: a checkpoint written before a restart is what the next session
reads FIRST. This client is the consumer path — `resolve` is what a platform's wake hook
calls, and it exits non-zero when there is nothing resumable, so a wake can decide without
parsing prose.

Exit codes
  0  ok / resumable
  1  nothing to resume (missing file, or phase != the configured auto-resume phase)
  2  usage / unusable config
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

EXIT_OK, EXIT_NOT_RESUMABLE, EXIT_USAGE = 0, 1, 2
PHASES = ("ACTIVE", "IDLE")


# --------------------------------------------------------------------------- config
def load_config(path: str) -> dict:
    text = Path(path).read_text()
    try:
        import yaml

        return yaml.safe_load(text) or {}
    except ImportError:
        root = {}
        for raw in text.splitlines():
            line = raw.split(" #")[0].strip()
            if not line or line.startswith("#") or line.startswith("-"):
                continue
            key, _, value = line.partition(":")
            root[key.strip()] = value.strip().strip('"').strip("'")
        return root


def expand(path: str) -> Path:
    """YAML does not expand ~ or $VAR — the tool must, or every install gets a literal '~' dir."""
    return Path(os.path.expanduser(os.path.expandvars(str(path))))


class Paths:
    def __init__(self, cfg: dict):
        for key in ("resume_file", "checkpoints_dir"):
            if not cfg.get(key):
                raise ValueError(f"config is missing `{key}`")
        self.resume_file = expand(cfg["resume_file"])
        self.checkpoints_dir = expand(cfg["checkpoints_dir"])
        self.auto_resume_phase = str(cfg.get("auto_resume_phase") or "ACTIVE").upper()
        if self.auto_resume_phase not in PHASES:
            raise ValueError(f"auto_resume_phase must be one of {PHASES}, got {self.auto_resume_phase!r}")


# --------------------------------------------------------------------------- operations
def save(paths: Paths, title: str, state: str, next_step: str, phase: str) -> dict:
    phase = phase.upper()
    if phase not in PHASES:
        raise ValueError(f"phase must be one of {PHASES}, got {phase!r}")
    record = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "title": title,
        "state": state,
        "next": next_step,
        "phase": phase,
    }
    paths.resume_file.parent.mkdir(parents=True, exist_ok=True)
    paths.checkpoints_dir.mkdir(parents=True, exist_ok=True)
    # Atomic: a crash mid-write must never leave a half checkpoint as ground truth.
    tmp = paths.resume_file.with_suffix(paths.resume_file.suffix + ".tmp")
    tmp.write_text(json.dumps(record, indent=2) + "\n")
    os.replace(tmp, paths.resume_file)
    snapshot = paths.checkpoints_dir / f"{time.strftime('%Y%m%dT%H%M%S', time.gmtime())}-{os.getpid()}.json"
    snapshot.write_text(json.dumps(record) + "\n")
    return record


def read(paths: Paths) -> dict | None:
    if not paths.resume_file.is_file():
        return None
    try:
        return json.loads(paths.resume_file.read_text())
    except ValueError:
        return None


def resolve(paths: Paths) -> tuple[bool, str, dict | None]:
    """The wake decision. Returns (resumable, reason, record)."""
    record = read(paths)
    if record is None:
        return False, "no checkpoint file at the configured path", None
    phase = str(record.get("phase") or "").upper()
    if phase != paths.auto_resume_phase:
        return False, f"phase is {phase or 'unset'}, auto-resume requires {paths.auto_resume_phase}", record
    if not record.get("title"):
        return False, "checkpoint has no title", record
    return True, f"resume {record.get('title')!r}", record


def clear(paths: Paths) -> bool:
    if paths.resume_file.is_file():
        paths.resume_file.unlink()
        return True
    return False


# --------------------------------------------------------------------------- cli
def _paths(args) -> Paths:
    try:
        return Paths(load_config(args.config))
    except (OSError, ValueError) as exc:
        print(f"USAGE: {exc}", file=sys.stderr)
        raise SystemExit(EXIT_USAGE)


def main(argv: list[str] | None = None) -> int:
    default_cfg = Path(os.environ.get("COFA_CONFIG_DIR", Path.home() / ".config" / "cofa")) \
        / "continuity" / "config.yaml"
    parser = argparse.ArgumentParser(prog="checkpoint.py", description="COFA continuity client")
    parser.add_argument("--config", default=str(default_cfg))
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_save = sub.add_parser("save", help="write the checkpoint (atomically) and snapshot it")
    p_save.add_argument("--title", required=True)
    p_save.add_argument("--state", required=True)
    p_save.add_argument("--next", required=True, dest="next_step")
    p_save.add_argument("--phase", default=None, help="ACTIVE (default) or IDLE")

    sub.add_parser("resolve", help="wake decision: exit 0 only when resumable")
    sub.add_parser("show", help="print the checkpoint as JSON")
    sub.add_parser("clear", help="delete the checkpoint file")

    args = parser.parse_args(argv)
    paths = _paths(args)

    if args.cmd == "save":
        phase = args.phase or paths.auto_resume_phase
        try:
            record = save(paths, args.title, args.state, args.next_step, phase)
        except (OSError, ValueError) as exc:
            print(f"OP-FAILED: {exc}", file=sys.stderr)
            return EXIT_USAGE
        print(f"SAVED {paths.resume_file} phase={record['phase']}")
        return EXIT_OK

    if args.cmd == "show":
        record = read(paths)
        if record is None:
            print(f"MISSING {paths.resume_file}", file=sys.stderr)
            return EXIT_NOT_RESUMABLE
        print(json.dumps(record, indent=2))
        return EXIT_OK

    if args.cmd == "clear":
        print("CLEARED" if clear(paths) else "ALREADY-ABSENT")
        return EXIT_OK

    resumable, reason, record = resolve(paths)
    if resumable and record is not None:
        print(f"RESUMABLE: {reason}")
        print(json.dumps({"title": record.get("title"), "state": record.get("state"),
                          "next": record.get("next"), "phase": record.get("phase")}))
        return EXIT_OK
    print(f"NOT-RESUMABLE: {reason}", file=sys.stderr)
    return EXIT_NOT_RESUMABLE


if __name__ == "__main__":
    sys.exit(main())
