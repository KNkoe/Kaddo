#!/usr/bin/env python3
"""One-purpose MCP broker for the local verification gate. No shell or workspace execution."""
import json
import os
from pathlib import Path
import subprocess
import sys
from urllib.request import urlopen

MAX_BYTES = 65536
RUNTIME = Path(__file__).resolve().parent / "runtime"
MODEL = "aac6fef/laya-multilingual-mlx"
REVISION = "f2b4faf51023039425946074e2cf1361d2db11d5"

def check_runtime():
    setup = RUNTIME / "setup.py"
    instruction = f"Run python3.12 '{setup}' to provision Kaddo's pinned local verification runtime."
    if not all((RUNTIME / name).is_file() for name in ("verify.py", "local_laya_client.py")):
        raise ValueError("Bundled verifier is incomplete. Rebuild Kaddo.")
    try:
        with urlopen("http://127.0.0.1:8765/health", timeout=2) as response:
            status = json.load(response)
        if (status.get("ok") is not True or status.get("model") != MODEL
                or status.get("revision") != REVISION or status.get("verification_input_attestation") is not True):
            raise ValueError("Unexpected local verification model")
        if not (Path.home() / ".config/codex-local-laya/token").is_file():
            raise ValueError("Local verification credential is missing")
    except Exception as error:
        raise ValueError(f"Verification runtime unavailable ({type(error).__name__}). {instruction}")
SCHEMA = {"type": "object", "properties": {"task": {"type": "string", "maxLength": 4000}, "evidence": {"type": "object"}, "attempt": {"type": "integer", "minimum": 1, "maximum": 3}}, "required": ["task", "evidence", "attempt"], "additionalProperties": False}

def verify(arguments):
    if not isinstance(arguments, dict) or set(arguments) != {"task", "evidence", "attempt"}:
        raise ValueError("Expected only task, evidence and attempt")
    if not isinstance(arguments["task"], str) or not 1 <= len(arguments["task"]) <= 4000:
        raise ValueError("Task is empty or too long")
    if not isinstance(arguments["evidence"], dict) or type(arguments["attempt"]) is not int or not 1 <= arguments["attempt"] <= 3:
        raise ValueError("Invalid evidence or attempt")
    checks = arguments["evidence"].get("deterministic_checks")
    if not isinstance(checks, list) or not checks:
        raise ValueError("deterministic_checks must list actual command/exit_code/output records, not bare pass flags")
    for check in checks:
        if (not isinstance(check, dict) or not isinstance(check.get("command"), str)
                or not check["command"].strip() or type(check.get("exit_code")) is not int
                or not (isinstance(check.get("stdout"), str)
                        or ("expected" in check and "actual" in check))):
            raise ValueError("Each check needs command, integer exit_code, and stdout or expected/actual measurements. Retain all requirements; archive full proof and submit concise complete output.")
    payload = json.dumps(arguments, allow_nan=False)
    if len(payload.encode()) > MAX_BYTES:
        raise ValueError("Evidence exceeds 64 KiB")
    gate = RUNTIME / "verify.py"
    env = {k: v for k, v in os.environ.items() if not k.startswith("LOCAL_LAYA_") and not k.startswith("PYTHON")}
    env.update(LOCAL_LAYA_URL="http://127.0.0.1:8765", LOCAL_LAYA_TIMEOUT="45", PYTHONNOUSERSITE="1")
    # Evidence and deterministic checks come from the sandbox. Never run git or
    # any agent-controlled code/configuration outside it (including --collect).
    result = subprocess.run(["/usr/bin/python3", "-E", "-s", str(gate)], input=payload, text=True, capture_output=True, cwd="/", env=env, timeout=55)
    try:
        verdict = json.loads(result.stdout)
    except (ValueError, TypeError):
        raise ValueError("Local verification did not return JSON")
    if not isinstance(verdict, dict) or verdict.get("action") not in ("accept", "rerun", "escalate"):
        raise ValueError("Invalid local verification verdict")
    return verdict

def dispatch(request):
    method = request.get("method")
    if method == "initialize":
        check_runtime()
        return {"protocolVersion": request.get("params", {}).get("protocolVersion", "2024-11-05"), "capabilities": {"tools": {}}, "serverInfo": {"name": "kaddo-local-verifier", "version": "1.0"}}
    if method == "ping":
        return {}
    if method == "tools/list":
        return {"tools": [{"name": "verify_task", "description": "Run Kaddo's local completion gate. First run deterministic checks and collect evidence INSIDE the sandbox, then submit task/evidence/attempt here. deterministic_checks must be command/exit_code/stdout or expected/actual records, not bare pass flags. Keep all requirements and failures in concise complete evidence; archive raw proof files. Respects accept/rerun/escalate; no network or command execution is exposed to the agent.", "inputSchema": SCHEMA}]}
    if method == "tools/call":
        params = request.get("params", {})
        if params.get("name") != "verify_task":
            raise ValueError("Unknown verification tool")
        verdict = verify(params.get("arguments"))
        return {"content": [{"type": "text", "text": json.dumps(verdict)}], "isError": False}
    raise ValueError("Unsupported method")

def main():
    calls = 0
    while True:
        line = sys.stdin.buffer.readline(MAX_BYTES + 8193)
        if not line:
            break
        request = None
        try:
            if len(line) > MAX_BYTES + 8192:
                raise ValueError("Request is too large")
            request = json.loads(line)
            if not isinstance(request, dict):
                raise ValueError("Expected JSON-RPC object")
            if "id" not in request:
                continue
            if request.get("method") == "tools/call":
                calls += 1
                if calls > 3:
                    raise ValueError("Three verification calls per agent turn maximum")
            reply = {"jsonrpc": "2.0", "id": request["id"], "result": dispatch(request)}
        except Exception as error:
            reply = {"jsonrpc": "2.0", "id": request.get("id") if isinstance(request, dict) else None, "error": {"code": -32602, "message": str(error)[:300]}}
        print(json.dumps(reply, allow_nan=False), flush=True)
        if len(line) > MAX_BYTES + 8192:
            break

if __name__ == "__main__":
    main()
