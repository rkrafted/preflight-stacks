#!/usr/bin/env python3
"""Check the n8n workflow before importing it.

Two kinds of check, both runnable offline:
  1. structure: every connection points at a real node, every node is reachable from a trigger,
     the loop has a guard, and only node types this workflow is allowed to use appear;
  2. behaviour: each Code node is extracted and executed with `node`, against the JSON the CLI
     actually prints, so the parse/loop logic is tested rather than assumed.

Usage: python validate.py [stack-runner.json]
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

ALLOWED_TYPES = {
    "n8n-nodes-base.manualTrigger",
    "n8n-nodes-base.scheduleTrigger",
    "n8n-nodes-base.code",
    "n8n-nodes-base.executeCommand",
    "n8n-nodes-base.if",
    "n8n-nodes-base.wait",
    "n8n-nodes-base.noOp",
    "n8n-nodes-base.stopAndError",
}

TRIGGERS = {"n8n-nodes-base.manualTrigger", "n8n-nodes-base.scheduleTrigger"}
TERMINALS = {"n8n-nodes-base.noOp", "n8n-nodes-base.stopAndError"}


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def check_structure(wf: dict) -> list[str]:
    problems: list[str] = []
    nodes = wf.get("nodes") or []
    if not nodes:
        return ["no nodes"]
    names = [n.get("name") for n in nodes]
    ids = [n.get("id") for n in nodes]
    if len(set(names)) != len(names):
        problems.append("duplicate node names")
    if len(set(ids)) != len(ids):
        problems.append("duplicate node ids")

    by_name = {n["name"]: n for n in nodes}
    for node in nodes:
        for field in ("type", "typeVersion", "position", "parameters"):
            if field not in node:
                problems.append(f"{node.get('name')}: missing {field}")
        if node.get("type") not in ALLOWED_TYPES:
            problems.append(f"{node.get('name')}: unexpected type {node.get('type')}")
        pos = node.get("position")
        if not (isinstance(pos, list) and len(pos) == 2 and all(isinstance(v, (int, float)) for v in pos)):
            problems.append(f"{node.get('name')}: position must be [x, y]")
        params = node.get("parameters", {})
        if node.get("type") == "n8n-nodes-base.executeCommand":
            command = params.get("command", "")
            if not command.startswith("="):
                problems.append(f"{node.get('name')}: command should be an expression")
            if "run-preflight.js" not in command and ".runner" not in command:
                problems.append(f"{node.get('name')}: command must go through run-preflight.js")
        if node.get("type") == "n8n-nodes-base.code":
            code = params.get("jsCode", "")
            if "return" not in code:
                problems.append(f"{node.get('name')}: jsCode does not return a value")
        if node.get("type") == "n8n-nodes-base.stopAndError":
            if not str(params.get("errorMessage", "")).startswith("="):
                problems.append(f"{node.get('name')}: errorMessage should be an expression")

    connections = wf.get("connections") or {}
    for src, spec in connections.items():
        if src not in by_name:
            problems.append(f"connection from unknown node {src}")
            continue
        for branch, targets in enumerate(spec.get("main", [])):
            for target in targets:
                if target.get("node") not in by_name:
                    problems.append(f"{src}: branch {branch} points at unknown {target.get('node')}")
                if target.get("type") != "main":
                    problems.append(f"{src}: unexpected connection type {target.get('type')}")

    # reachability from any trigger
    seen: set[str] = set()
    stack = [n["name"] for n in nodes if n["type"] in TRIGGERS]
    if not stack:
        problems.append("no trigger node")
    while stack:
        name = stack.pop()
        if name in seen:
            continue
        seen.add(name)
        for branch in connections.get(name, {}).get("main", []):
            stack.extend(t.get("node") for t in branch)
    unreachable = set(by_name) - seen
    if unreachable:
        problems.append(f"unreachable nodes: {sorted(unreachable)}")

    # the loop must exist and must be guarded
    loop_back = [
        (src, target.get("node"))
        for src, spec in connections.items()
        for branch in spec.get("main", [])
        for target in branch
        if (src, target.get("node"))
        in {("Still waiting?", "Open next page"), ("Stall guard", "Wait for download")}
    ]
    if len(loop_back) != 2:
        problems.append("the polling loop is not wired")
    config = by_name.get("Config", {}).get("parameters", {}).get("jsCode", "")
    for field in ("runner", "preflight", "game", "stack", "downloads"):
        if f"{field}:" not in config:
            problems.append(f"Config is missing {field}")

    guard = by_name.get("Stall guard")
    if guard is None or "waitedMinutes" not in json.dumps(guard.get("parameters", {})):
        problems.append("Stall guard does not use waitedMinutes")

    for node in nodes:
        if node["type"] in TERMINALS and connections.get(node["name"], {}).get("main"):
            problems.append(f"{node['name']}: terminal node has outgoing connections")
    return problems


HARNESS = """
const fs = require('fs');
const spec = JSON.parse(fs.readFileSync(process.argv[process.argv.length - 1], 'utf8'));
const $json = spec.json;
const $ = (name) => ({ first: () => ({ json: spec.nodes[name] || {} }), item: { json: (spec.nodes[name] || {}) } });
const fn = new Function('$json', '$', 'return (function(){' + spec.code + '})()');
try {
  process.stdout.write(JSON.stringify(fn($json, $)));
} catch (e) {
  process.stdout.write(JSON.stringify({ error: String(e && e.message ? e.message : e) }));
}
"""


def run_code(code: str, json_input: dict, nodes: dict) -> dict:
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8") as handle:
        json.dump({"code": code, "json": json_input, "nodes": nodes}, handle)
        path = handle.name
    out = subprocess.run(["node", "-e", HARNESS, path], capture_output=True, text=True)
    Path(path).unlink(missing_ok=True)
    if out.returncode != 0:
        raise AssertionError(f"node failed: {out.stderr.strip()[:300]}")
    items = json.loads(out.stdout)
    if isinstance(items, dict) and "error" in items:
        raise AssertionError(f"node threw: {items['error']}")
    return items[0]["json"]


def envelope(exit_code: int, stdout: str, stderr: str = "") -> dict:
    return {"stdout": json.dumps({"exitCode": exit_code, "stdout": stdout, "stderr": stderr}), "stderr": "", "exitCode": 0}


def check_behaviour(wf: dict) -> list[str]:
    problems: list[str] = []
    nodes = {n["name"]: n["parameters"].get("jsCode", "") for n in wf["nodes"]}

    plan_ok = run_code(
        nodes["Parse plan"],
        envelope(0, json.dumps({"stack": "core-2.5", "automatic": 8, "nexus_clicks": 0, "members": []})),
        {},
    )
    if plan_ok["blockedCount"] != 0:
        problems.append("Parse plan flagged a clean stack as blocked")

    plan_bad = run_code(
        nodes["Parse plan"],
        envelope(3, json.dumps({"members": [{"id": "equipmentex", "blocked": "no GitHub release recorded for patch 2.5"}]})),
        {},
    )
    if plan_bad["blockedCount"] != 1 or "equipmentex" not in plan_bad["blockedText"] or plan_bad["exitCode"] != 3:
        problems.append("Parse plan did not report a blocked member")

    started = run_code(
        nodes["Parse step"],
        envelope(0, json.dumps({"position": 1, "total": 2, "id": "better-saves", "name": "Better Saves", "page": "https://www.nexusmods.com/cyberpunk2077/mods/1?tab=files"})),
        {},
    )
    if started["current"] != "better-saves":
        problems.append("Parse step did not keep the current member")

    finished = run_code(nodes["Parse step"], envelope(0, "null"), {})
    if finished["step"] is not None or finished["current"] is not None:
        problems.append("Parse step did not treat null as finished")

    parse_step_nodes = {"Parse step": {"openedAt": "2026-10-30T20:00:00Z", "current": "better-saves"}}
    waiting = run_code(
        nodes["Check"],
        envelope(0, json.dumps({"position": 1, "total": 2, "id": "better-saves", "page": "x"})),
        parse_step_nodes,
    )
    if waiting["state"] != "waiting":
        problems.append("Check did not say waiting for the same page")

    advanced = run_code(
        nodes["Check"],
        envelope(0, json.dumps({"position": 2, "total": 2, "id": "quick-tweak", "page": "y"})),
        parse_step_nodes,
    )
    if advanced["state"] != "advanced":
        problems.append("Check did not notice the next member")

    done = run_code(nodes["Check"], envelope(0, "null"), parse_step_nodes)
    if done["state"] != "done":
        problems.append("Check did not notice the queue finished")

    errored = run_code(nodes["Check"], envelope(2, "", "rules bundle missing"), parse_step_nodes)
    if errored["state"] != "error" or "rules bundle" not in errored["stderr"]:
        problems.append("Check did not surface a CLI error")

    # the wrapper is what turns exit 3 into data; prove it against a command that always fails
    for argv, expected in [(["/bin/true", "noop"], 0), (["/bin/false", "noop"], 1), (["/nonexistent/preflight", "noop"], 2)]:
        out = subprocess.run(["node", str(Path(__file__).with_name("run-preflight.js"))] + argv, capture_output=True, text=True)
        if out.returncode != 0:
            problems.append(f"run-preflight.js exited {out.returncode} for {argv}")
            continue
        try:
            env = json.loads(out.stdout)
        except json.JSONDecodeError:
            problems.append(f"run-preflight.js did not print an envelope for {argv}: {out.stdout[:120]}")
            continue
        if env.get("exitCode") != expected:
            problems.append(f"run-preflight.js reported {env.get('exitCode')} for {argv}, expected {expected}")

    return problems


def main(argv: list[str]) -> int:
    path = Path(argv[1] if len(argv) > 1 else "stack-runner.json")
    wf = load(path)
    problems = check_structure(wf) + check_behaviour(wf)
    if problems:
        print(f"{path}: {len(problems)} problem(s)")
        for problem in problems:
            print(f"  - {problem}")
        return 1
    nodes = wf["nodes"]
    loops = sum(1 for t in wf["connections"].values() for b in t["main"] for _ in b)
    print(f"{path}: ok - {len(nodes)} nodes, {loops} connections, loop guarded by Stall guard")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
