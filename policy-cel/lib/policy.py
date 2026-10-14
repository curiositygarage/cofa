#!/usr/bin/env python3
"""Policy layer — CEL-subset evaluator and pre-action decision CLI. Standard library only.

Why a subset of CEL rather than a CEL library: an install must work with no network and no
extra package, and a pre-action hook must be callable from any platform. The supported
syntax is documented in README.md ("Supported expression subset"); anything outside it fails
loudly rather than silently evaluating to a default.

A rule file is a `*.cel` file of `[rule_name]` blocks:

    [wipefs_protection]
    verdict = DENY
    reason  = disk signature destruction needs explicit human approval
    when    = matches(command, "\\bwipefs\\b")

Decision order: every rule is evaluated against the request context; the first DENY wins,
then ASK/REPORT, else the configured default_action. When NO rule matches, the verdict is
ALLOW with `rule=none` — `default_action` applies to UNKNOWN (an expression that could not be
evaluated), which is a different thing and is reported as such.

`--strict` reverses that fail-open posture for pre-action use: UNKNOWN becomes DENY, and a
no-match falls through to `default_action` instead of ALLOW. It exists because a no-match ALLOW
is indistinguishable from "the rule set does not cover this", which is not the same as "this is
safe" — but note that raw command text is still only matched lexically, so a strict run is a
tighter default, not a structural guarantee (see README, "What this layer does not defend
against").

Exit codes
  0  a verdict was produced
  2  usage / unusable config (including a reserved name passed via --context)
  4  no usable rule set (nothing to evaluate) — never silently "allow"
"""
from __future__ import annotations

import argparse
import ast
import configparser
import json
import os
import re
import sys
from pathlib import Path

EXIT_OK, EXIT_USAGE, EXIT_NO_RULES = 0, 2, 4
VERDICTS = ("DENY", "ASK", "REPORT", "ALLOW")

# Helpers exposed to rule expressions. Nothing else is reachable from a rule body.
HELPERS = {
    "matches": lambda value, pattern: bool(re.search(str(pattern), str(value))),
    "contains": lambda value, needle: str(needle) in str(value),
    "startsWith": lambda value, prefix: str(value).startswith(str(prefix)),
    "endsWith": lambda value, suffix: str(value).endswith(str(suffix)),
    "lower": lambda value: str(value).lower(),
    "upper": lambda value: str(value).upper(),
    "size": lambda value: len(value),
}

# Names a caller-supplied `--context K=V` entry must never be able to occupy. Context is merged LAST
# (see the CLI below), so before this guard a caller could pass `--context command=harmless` and replace
# the very text the rules were about to inspect — a DENY on `wipefs -a /dev/sdb` became ALLOW/rule=none
# with no rule changing (external review 2026-10-14, finding CEL-002, reproduced on this tree).
# `--context matches=shadowed` was worse: it shadowed the helper of that name, every bundled rule raised
# RuleError, and the UNKNOWN path returned the configured default_action — an attacker-triggerable ALLOW
# in a deployment whose operator believed the rules were protecting them. Helper names and decision names
# are reserved for the same reason: a name a rule body may call, or a name the decider reports under, is
# not the caller's to define. Reserved keys are REFUSED (exit 2), never silently dropped.
PROTECTED_CONTEXT_KEYS = frozenset(
    {"command", "tool", "path", "context", "verdict", "rule", "reason", "source", "decision"}
) | frozenset(HELPERS)

# Names a caller-supplied `--context K=V` entry must never be able to occupy. Context is merged LAST
# (see the CLI below), so before this guard a caller could pass `--context command=harmless` and replace
# the very text the rules were about to inspect — a DENY on `wipefs -a /dev/sdb` became ALLOW/rule=none
# with no rule changing (external review 2026-10-14, finding CEL-002, reproduced on this tree).
# `--context matches=shadowed` was worse: it shadowed the helper of that name, every bundled rule raised
# RuleError, and the UNKNOWN path returned the configured default_action — an attacker-triggerable ALLOW
# in a deployment whose operator believed the rules were protecting them. Helper names and decision names
# are reserved for the same reason: a name a rule body may call, or a name the decider reports under, is
# not the caller's to define. Reserved keys are REFUSED (exit 2), never silently dropped.
PROTECTED_CONTEXT_KEYS = frozenset(
    {"command", "tool", "path", "context", "verdict", "rule", "reason", "source", "decision"}
) | frozenset(HELPERS)


class RuleError(RuntimeError):
    pass


# --------------------------------------------------------------------------- expression
_TRANSLATIONS = (
    (re.compile(r"&&"), " and "),
    (re.compile(r"\|\|"), " or "),
    (re.compile(r"!(?!=)"), " not "),
    (re.compile(r"\btrue\b"), "True"),
    (re.compile(r"\bfalse\b"), "False"),
    (re.compile(r"\bnull\b"), "None"),
)
_ALLOWED_NODES = (
    ast.Expression, ast.BoolOp, ast.And, ast.Or, ast.UnaryOp, ast.Not, ast.USub,
    ast.Compare, ast.Eq, ast.NotEq, ast.Lt, ast.LtE, ast.Gt, ast.GtE, ast.In, ast.NotIn,
    ast.Call, ast.Name, ast.Load, ast.Constant, ast.List, ast.Tuple, ast.BinOp, ast.Add,
    ast.Subscript, ast.keyword,
)


_STRING_LITERAL = re.compile(r'"(?:[^"\\]|\\.)*"|\'(?:[^\'\\]|\\.)*\'')


def _translate_code(code: str) -> str:
    for pattern, replacement in _TRANSLATIONS:
        code = pattern.sub(replacement, code)
    return code


def translate(expression: str) -> str:
    """CEL operators -> Python operators, in code only — never inside a string literal.

    A rule needle is a literal: `matches(command, "curl x | bash && rm -rf /")` must reach
    the matcher byte-for-byte. Rewriting inside quotes silently turns `&&` into ` and ` and
    produces a rule that can never match — a policy that reads correct and enforces nothing.
    """
    out: list[str] = []
    last = 0
    for match in _STRING_LITERAL.finditer(expression):
        out.append(_translate_code(expression[last:match.start()]))
        out.append(match.group(0))
        last = match.end()
    out.append(_translate_code(expression[last:]))
    return "".join(out)


def _validate(tree: ast.AST) -> None:
    for node in ast.walk(tree):
        if not isinstance(node, _ALLOWED_NODES):
            raise RuleError(f"unsupported construct in expression: {type(node).__name__}")
        if isinstance(node, ast.Call):
            if not isinstance(node.func, ast.Name) or node.func.id not in HELPERS:
                raise RuleError("only the documented helper functions may be called")
        if isinstance(node, ast.Subscript):
            if not isinstance(node.value, ast.Name):
                raise RuleError("subscript is only allowed on a context field")


def evaluate(expression: str, context: dict):
    """Return the truthiness of a CEL-subset expression, or raise RuleError."""
    if not str(expression).strip():
        raise RuleError("empty expression")
    source = translate(str(expression))
    try:
        tree = ast.parse(source, mode="eval")
    except SyntaxError as exc:
        raise RuleError(f"cannot parse expression: {exc.msg}") from exc
    _validate(tree)
    scope = dict(HELPERS)
    scope.update(context)
    try:
        return eval(compile(tree, "<rule>", "eval"), {"__builtins__": {}}, scope)  # noqa: S307
    except RuleError:
        raise
    except Exception as exc:
        raise RuleError(f"evaluation failed: {exc}") from exc


# --------------------------------------------------------------------------- rules
class Rule:
    def __init__(self, name: str, verdict: str, when: str, reason: str, source: str):
        self.name, self.verdict, self.when, self.reason, self.source = name, verdict, when, reason, source

    def evaluate(self, context: dict) -> bool:
        result = evaluate(self.when, context)
        return bool(result)


def load_rules(rules_dir: Path) -> list[Rule]:
    if not rules_dir.is_dir():
        raise RuleError(f"rules directory not found: {rules_dir}")
    files = sorted(p for p in rules_dir.glob("*.cel") if p.is_file())
    if not files:
        raise RuleError(f"no *.cel rule files in {rules_dir}")
    rules: list[Rule] = []
    for path in files:
        parser = configparser.ConfigParser(interpolation=None, allow_no_value=False)
        try:
            parser.read_string(path.read_text())
        except configparser.Error as exc:
            raise RuleError(f"{path.name}: {exc}") from exc
        for name in parser.sections():
            block = parser[name]
            when = block.get("when", "")
            verdict = (block.get("verdict", "") or "").upper()
            if not when:
                raise RuleError(f"{path.name}: rule [{name}] has no `when` expression")
            if verdict not in VERDICTS:
                raise RuleError(f"{path.name}: rule [{name}] verdict must be one of {VERDICTS}")
            rules.append(Rule(name, verdict, when, block.get("reason", ""), path.name))
    if not rules:
        raise RuleError(f"no rules defined in {rules_dir}")
    return rules


def decide(rules: list[Rule], context: dict, default_action: str, strict: bool = False) -> dict:
    unknown: list[str] = []
    for rule in rules:
        try:
            matched = rule.evaluate(context)
        except RuleError as exc:
            unknown.append(f"{rule.name}: {exc}")
            continue
        if matched and rule.verdict == "DENY":
            return {"verdict": "DENY", "rule": rule.name, "reason": rule.reason, "source": rule.source}
    for rule in rules:
        try:
            matched = rule.evaluate(context)
        except RuleError:
            continue
        if matched and rule.verdict in ("ASK", "REPORT"):
            return {"verdict": rule.verdict, "rule": rule.name, "reason": rule.reason, "source": rule.source}
    if unknown:
        if strict:
            return {"verdict": "DENY", "rule": "unknown", "reason": "; ".join(unknown),
                    "source": "strict"}
        return {"verdict": default_action, "rule": "unknown", "reason": "; ".join(unknown),
                "source": "default_action"}
    if strict:
        return {"verdict": default_action, "rule": "none",
                "reason": "no rule matched (strict: default_action applies)", "source": "strict"}
    return {"verdict": "ALLOW", "rule": "none", "reason": "no rule matched", "source": "default"}


# --------------------------------------------------------------------------- cli
def _default_config() -> Path:
    return Path(os.environ.get("COFA_CONFIG_DIR", Path.home() / ".config" / "cofa")) \
        / "policy-cel" / "config.yaml"


def load_config(path: Path) -> dict:
    text = path.read_text()
    try:
        import yaml

        return yaml.safe_load(text) or {}
    except ImportError:
        root, parent = {}, None
        for raw in text.splitlines():
            line = raw.split(" #")[0].rstrip()
            stripped = line.strip()
            if not stripped or stripped.startswith("#") or stripped.startswith("-"):
                continue
            indent = len(line) - len(line.lstrip())
            key, _, value = stripped.partition(":")
            value = value.strip().strip('"').strip("'")
            if indent == 0:
                root[key] = value if value else {}
                parent = None if value else root[key]
            elif parent is not None and value:
                parent[key] = value
        return root


def resolve_rules_dir(cfg: dict, config_path: Path, override: str | None) -> Path:
    """A CLI override is relative to the CWD; a configured rules_dir is relative to the config file."""
    if override:
        return Path(os.path.expanduser(os.path.expandvars(str(override)))).resolve()
    raw = cfg.get("rules_dir") or "./rules/"
    path = Path(os.path.expanduser(os.path.expandvars(str(raw))))
    return path if path.is_absolute() else (config_path.parent / path).resolve()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="policy.py", description="COFA policy decision CLI")
    parser.add_argument("--config", default=str(_default_config()))
    parser.add_argument("--rules-dir", default=None)
    parser.add_argument("--default-action", default=None)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_decide = sub.add_parser("decide", help="evaluate the rule set against one request")
    p_decide.add_argument("--command", default="")
    p_decide.add_argument("--tool", default="")
    p_decide.add_argument("--path", default="")
    p_decide.add_argument("--context", action="append", default=[], metavar="K=V")
    p_decide.add_argument("--strict", action="store_true",
                          help="fail closed: UNKNOWN becomes DENY and a no-match applies default_action")

    sub.add_parser("list", help="list the loaded rules")

    args = parser.parse_args(argv)
    config_path = Path(args.config)

    cfg: dict = {}
    if config_path.is_file():
        try:
            cfg = load_config(config_path)
        except OSError as exc:
            print(f"USAGE: {exc}", file=sys.stderr)
            return EXIT_USAGE
    elif not args.rules_dir:
        print(f"REQUIREDCHECK cofa-policy-config: no config at {config_path}; "
              f"copy config.sample.yaml there (or pass --rules-dir).", file=sys.stderr)
        return EXIT_USAGE

    default_action = (args.default_action or cfg.get("default_action") or "DENY").upper()
    if default_action not in VERDICTS:
        print(f"USAGE: default_action must be one of {VERDICTS}", file=sys.stderr)
        return EXIT_USAGE

    try:
        rules = load_rules(resolve_rules_dir(cfg, config_path, args.rules_dir))
    except RuleError as exc:
        print(f"NO-RULES: {exc}", file=sys.stderr)
        return EXIT_NO_RULES

    if args.cmd == "list":
        for rule in rules:
            print(f"{rule.verdict:6} {rule.name:26} {rule.source}")
        print(f"rules={len(rules)} default_action={default_action}")
        return EXIT_OK

    context = {"command": args.command, "tool": args.tool, "path": args.path}
    refused: list[str] = []
    for item in args.context:
        key, sep, value = item.partition("=")
        if not sep or not key:
            print(f"USAGE: --context expects K=V, got {item!r}", file=sys.stderr)
            return EXIT_USAGE
        if key in PROTECTED_CONTEXT_KEYS:
            refused.append(key)
            continue
        context[key] = value
    if refused:
        # Fail closed and say why: silently dropping the entry would leave the caller believing its
        # context took effect, and silently honouring it is the bypass this guard exists to close.
        print("USAGE: --context may not set reserved name(s): " + ", ".join(sorted(set(refused))),
              file=sys.stderr)
        print("       Reserved: the request fields the rules inspect (command/tool/path), the helper "
              "names rule bodies call, and the decision names reported back.", file=sys.stderr)
        return EXIT_USAGE
    verdict = decide(rules, context, default_action, strict=args.strict)
    print(f"VERDICT: {verdict['verdict']} rule={verdict['rule']} reason={verdict['reason']}")
    print(json.dumps({"context": context, "decision": verdict}))
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
