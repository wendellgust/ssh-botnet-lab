#!/usr/bin/env python3
"""
Honeypot Logger — runs alongside sshd on victim-b containers
Watches auth.log and generates structured honeypot events.
When LAB_ROLE=honeypot, logs every interaction with full detail.
"""

import time
import re
import json
import os
import sys
from datetime import datetime

LOG_PATH = "/var/log/auth.log"
OUT_PATH = "/var/log/lab/honeypot_events.jsonl"
ROLE = os.environ.get("LAB_ROLE", "victim")

FAILED_RE = re.compile(
    r"Failed password for (?:invalid user )?(?P<user>\S+) from (?P<src_ip>[\d.]+) port (?P<src_port>\d+)"
)
ACCEPT_RE = re.compile(
    r"Accepted password for (?P<user>\S+) from (?P<src_ip>[\d.]+) port (?P<src_port>\d+)"
)
INVALID_RE = re.compile(
    r"Invalid user (?P<user>\S+) from (?P<src_ip>[\d.]+)"
)

def tail_log(path):
    """Yield new lines from a log file as they appear."""
    try:
        with open(path, "r") as f:
            f.seek(0, 2)  # seek to end
            while True:
                line = f.readline()
                if line:
                    yield line.rstrip()
                else:
                    time.sleep(0.5)
    except FileNotFoundError:
        print(f"[honeypot_logger] Waiting for {path}...")
        time.sleep(5)

def emit_event(event_type, data):
    event = {
        "ts": datetime.utcnow().isoformat(),
        "role": ROLE,
        "hostname": os.uname().nodename,
        "event": event_type,
        **data
    }
    line = json.dumps(event)
    print(f"[HONEYPOT EVENT] {line}", flush=True)
    os.makedirs(os.path.dirname(OUT_PATH), exist_ok=True)
    with open(OUT_PATH, "a") as f:
        f.write(line + "\n")

def main():
    print(f"[honeypot_logger] Starting on role={ROLE}, watching {LOG_PATH}")
    for line in tail_log(LOG_PATH):
        m = FAILED_RE.search(line)
        if m:
            emit_event("ssh_failed_auth", {
                "user": m.group("user"), "src_ip": m.group("src_ip"), "src_port": m.group("src_port")
            })
            continue
        m = ACCEPT_RE.search(line)
        if m:
            emit_event("ssh_successful_auth", {
                "user": m.group("user"), "src_ip": m.group("src_ip"), "src_port": m.group("src_port"),
                "severity": "CRITICAL" if ROLE == "honeypot" else "HIGH"
            })
            continue
        m = INVALID_RE.search(line)
        if m:
            emit_event("ssh_invalid_user", {
                "user": m.group("user"), "src_ip": m.group("src_ip")
            })

if __name__ == "__main__":
    main()
