#!/usr/bin/env python3
"""Provision the pinned loopback verifier explicitly; --check is read-only."""
import argparse
import json
import os
from pathlib import Path
import platform
import plistlib
import secrets
import shutil
import socket
import subprocess
import sys
import time
from urllib.request import urlopen

MODEL = "aac6fef/laya-multilingual-mlx"
REVISION = "f2b4faf51023039425946074e2cf1361d2db11d5"
SOURCE = Path(__file__).resolve().parent
ROOT = Path.home() / ".local/share/kaddo-verifier"
TOKEN = Path.home() / ".config/codex-local-laya/token"

def ready():
    try:
        with urlopen("http://127.0.0.1:8765/health", timeout=2) as response:
            status = json.load(response)
        return (status.get("ok") is True and status.get("model") == MODEL
                and status.get("revision") == REVISION and TOKEN.is_file()
                and status.get("verification_input_attestation") is True
                and len(TOKEN.read_text().strip()) >= 32)
    except Exception:
        return False

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    if ready():
        print("Verification runtime ready: pinned local Laya, loopback only.")
        return 0
    if args.check:
        print(f"Verification runtime unavailable. Run python3.12 '{SOURCE / 'setup.py'}'.", file=sys.stderr)
        return 1
    if platform.system() != "Darwin" or platform.machine() != "arm64" or sys.version_info < (3, 12):
        parser.error("Provisioning requires Apple Silicon macOS and Python 3.12+. --check never installs anything.")
    with socket.socket() as probe:
        probe.settimeout(1)
        if probe.connect_ex(("127.0.0.1", 8765)) == 0:
            parser.error("A different or unconfigured service already uses port 8765. Configure it before provisioning; it was not stopped or replaced.")
    ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
    python = ROOT / "venv/bin/python"
    if not python.is_file():
        subprocess.run([sys.executable, "-m", "venv", str(ROOT / "venv")], check=True)
    subprocess.run([str(python), "-m", "pip", "install", "-r", str(SOURCE / "requirements.txt")], check=True)
    if not TOKEN.exists():
        TOKEN.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        fd = os.open(TOKEN, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as stream:
            stream.write(secrets.token_hex(32))
    if len(TOKEN.read_text().strip()) < 32:
        parser.error("Existing local credential is invalid; it was preserved. Repair it before provisioning.")
    shutil.copy2(SOURCE / "laya_server.py", ROOT / "laya_server.py")
    environment = dict(os.environ, HF_HOME=str(ROOT / "hf-cache"))
    print("Preparing pinned local model; this may download public model files.")
    subprocess.run([str(python), "-c", "import laya_mlx; laya_mlx.load(" + repr(MODEL) + ", revision=" + repr(REVISION) + ")"], env=environment, check=True)
    agents = Path.home() / "Library/LaunchAgents"
    agents.mkdir(parents=True, exist_ok=True)
    plist = agents / "com.kaddo.local-verifier.plist"
    config = {"Label":"com.kaddo.local-verifier", "ProgramArguments":[str(python),str(ROOT / "laya_server.py")],
              "RunAtLoad":True, "KeepAlive":True, "WorkingDirectory":str(ROOT),
              "EnvironmentVariables":{"HF_HOME":str(ROOT / "hf-cache"), "CODEX_LAYA_MODEL":MODEL,
                  "CODEX_LAYA_REVISION":REVISION, "CODEX_LAYA_TOKEN_FILE":str(TOKEN), "CODEX_LAYA_PORT":"8765"},
              "StandardOutPath":str(ROOT / "service.log"), "StandardErrorPath":str(ROOT / "service-error.log")}
    plist.write_bytes(plistlib.dumps(config))
    target = f"gui/{os.getuid()}"
    subprocess.run(["launchctl","bootout",target + "/com.kaddo.local-verifier"], capture_output=True)
    subprocess.run(["launchctl","bootstrap",target,str(plist)], check=True)
    for _ in range(30):
        if ready():
            print("Verification runtime provisioned and healthy.")
            return 0
        time.sleep(1)
    print(f"Runtime did not become healthy; inspect {ROOT / 'service-error.log'}.", file=sys.stderr)
    return 1

if __name__ == "__main__":
    raise SystemExit(main())
