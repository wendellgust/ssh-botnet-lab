# SSH Brute-Force & Botnet Simulation Lab

> **For cybersecurity research and defensive education only.**
> All traffic is contained within isolated Docker bridge networks.
> No container has access to the internet or the host system.

---

## Table of contents

1. [What this lab does](#what-this-lab-does)
2. [Safety boundaries](#safety-boundaries)
3. [Architecture](#architecture)
4. [File structure](#file-structure)
5. [How to run the lab](#how-to-run-the-lab)
6. [What to look at](#what-to-look-at)
7. [Firewall concepts demonstrated](#firewall-concepts-demonstrated)
8. [Botnet concepts simulated](#botnet-concepts-simulated)
9. [Detection techniques](#detection-techniques)
10. [How to stop and clean up](#how-to-stop-and-clean-up)
11. [Limitations](#limitations)
12. [Educational notes](#educational-notes)

---

## What this lab does

This lab creates a miniature network environment where:

- An **attacker container** simulates SSH brute-force, network scanning, C2 beaconing, and lateral movement using Python scripts
- Multiple **victim containers** run real OpenSSH servers with intentionally weak configurations, generating authentic auth logs
- A **honeypot** in a segmented network catches lateral movement attempts
- A **monitor container** collects logs and runs detection rules to identify each attack pattern

The purpose is to study:
- How SSH brute-force attacks behave at the log level
- How firewall rules limit or allow attack propagation
- How network segmentation slows lateral movement
- How detection rules identify attack patterns
- How botnet C2 communication looks on the wire

---

## Safety boundaries

| Boundary | How it is enforced |
|---|---|
| No internet access | All Docker networks use `internal: true` |
| No host filesystem access | No host volumes are mounted in victim/attacker containers |
| No privileged containers | All containers use `cap_drop: ALL` plus minimal capability adds |
| No real attack tools | Attacker container has no hydra, metasploit, or nmap |
| Isolated networks | Three bridge networks with no external routing |
| Read-only script mounts | Attacker scripts mounted as `:ro` |
| Safety check in simulator | Python safety_check() refuses to target non-lab IPs |

---

## Architecture

```
                        YOUR HOST MACHINE
┌───────────────────────────────────────────────────────────────┐
│                                                               │
│  ┌─────────────────── attack-net ──────────────────────────┐  │
│  │             172.20.0.0/24   (internal: true)            │  │
│  │                                                         │  │
│  │  [attacker]          [victim1]           [victim2]      │  │
│  │  172.20.0.10         172.20.0.20         172.20.0.21    │  │
│  │  Kali/Python sim     Ubuntu+SSH          Ubuntu+SSH     │  │
│  └──────────────────────────────────────────────────────── ┘  │
│                              │ (victim1 is dual-homed)         │
│  ┌─────────────────── internal-net ────────────────────────┐  │
│  │             10.10.0.0/24   (internal: true)             │  │
│  │                                                         │  │
│  │  [victim3]           [honeypot]          [victim4]      │  │
│  │  10.10.0.10          10.10.0.50          10.10.0.11     │  │
│  │  (only via pivot)    (deception trap)    (only via pivot)│  │
│  └─────────────────────────────────────────────────────────┘  │
│                                                               │
│  ┌─────────────────── monitor-net ─────────────────────────┐  │
│  │             192.168.100.0/24  (internal: true)          │  │
│  │  All containers connected here for log collection       │  │
│  │  [monitor] 192.168.100.100                              │  │
│  └─────────────────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────────────────┘
```

**Attack chain modeled:**
```
attacker ──[SSH brute-force]──► victim1 (compromised)
victim1  ──[lateral movement]──► victim3  (Network B)
victim1  ──[lateral movement]──► honeypot (triggers alert)
all bots ──[C2 beacon]─────────► attacker (C2 listener)
```

---

## File structure

```
ssh-botnet-lab/
│
├── docker-compose.yml          Main lab definition — networks + services
│
├── attacker/
│   ├── Dockerfile              Ubuntu + Python3 + paramiko (no attack tools)
│   ├── entrypoint.sh           Safety warning + bash shell
│   └── simulator.py            Botnet behavior simulator (6 modules)
│
├── victim/                     Network A victims (172.20.0.x)
│   ├── Dockerfile              Ubuntu + OpenSSH + rsyslog + iptables
│   ├── sshd_config             Intentionally weak SSH config (annotated)
│   ├── rsyslog.conf            Structured auth log configuration
│   ├── firewall_setup.sh       iptables demo: weak / moderate / hardened
│   └── entrypoint.sh           Starts sshd + rsyslog
│
├── victim-b/                   Network B victims (10.10.0.x) + honeypot
│   ├── Dockerfile              Ubuntu + OpenSSH + honeypot logger
│   ├── sshd_config             Same weak config (for lab)
│   ├── rsyslog.conf            Auth log configuration
│   ├── honeypot_logger.py      Parses auth.log → structured JSON events
│   └── entrypoint.sh           Starts sshd + honeypot logger
│
├── monitor/
│   ├── Dockerfile              Ubuntu + Python3 + tcpdump
│   ├── analyzer.py             Log analyzer with 6 detection rules
│   ├── entrypoint.sh           Welcome banner + bash
│   └── rules/
│       └── ssh_botnet.rules    Suricata/Snort detection rules (14 rules)
│
└── README.md                   This file
```

### What each file does

| File | Purpose |
|---|---|
| `docker-compose.yml` | Defines all containers, networks, IP assignments, and security constraints |
| `attacker/simulator.py` | The core of the lab — 6 Python simulation modules for different attack behaviors |
| `victim/sshd_config` | Weak SSH config with annotations explaining each vulnerability |
| `victim/firewall_setup.sh` | Interactive firewall demo — shows weak/moderate/hardened iptables rules |
| `victim-b/honeypot_logger.py` | Tails auth.log and emits structured JSON events for the analyzer |
| `monitor/analyzer.py` | Detection engine — 6 rules that identify attack patterns in logs |
| `monitor/rules/ssh_botnet.rules` | Suricata/Snort rules for real network-level detection |

---

## How to run the lab

### Prerequisites

```bash
# Podman (Kali default) or Docker
podman compose version
# or
docker compose version
```

### Start all containers

```bash
cd ssh-botnet-lab
docker compose up -d --build
# or
podman compose up -d --build

# Verify all containers are running
docker compose ps
```

### Run the full botnet scenario

```bash
# Enter the attacker container
docker exec -it attacker bash

# Run the full scenario (all attack phases in sequence)
python3 /lab/simulator.py botnet

# Or run individual modules:
python3 /lab/simulator.py bruteforce --target 172.20.0.20
python3 /lab/simulator.py scan --network 172.20.0.
python3 /lab/simulator.py c2 --c2-host 172.20.0.10 --count 5
python3 /lab/simulator.py lateral --pivot 172.20.0.20
python3 /lab/simulator.py infected --duration 60
```

### Watch logs on a victim

```bash
# In a separate terminal — watch auth.log in real time
docker exec -it victim1 tail -f /var/log/auth.log
```

### Run the detection analyzer

```bash
# Enter monitor container
docker exec -it monitor bash

# Run full analysis
python3 /lab/monitor/analyzer.py

# Live monitoring mode
python3 /lab/monitor/analyzer.py --live

# Print summary report
python3 /lab/monitor/analyzer.py --report

# List all detection rules
python3 /lab/monitor/analyzer.py --rules
```

### Demonstrate firewall concepts

```bash
# Inside victim1 — demonstrate all three firewall states
docker exec -it victim1 bash

# Start with no firewall (default)
bash /lab/firewall_setup.sh weak

# Add logging and rate-limiting
bash /lab/firewall_setup.sh moderate

# Full hardening (blocks attacker)
bash /lab/firewall_setup.sh hardened

# Then run brute-force again from attacker — it should be blocked
```

---

## What logs to inspect

| Log | Location | What it shows |
|---|---|---|
| SSH auth events | `docker exec victim1 cat /var/log/auth.log` | Every login attempt, success, failure |
| Honeypot events | `docker exec honeypot cat /var/log/lab/honeypot_events.jsonl` | Structured attack events |
| Analyzer output | `docker exec monitor python3 /lab/monitor/analyzer.py` | Detection alerts |
| Network traffic | Run Wireshark on `br-*` interface on host | Packet-level view of all attack traffic |

### What to look for in auth.log

```
# Failed brute-force attempt:
May 13 14:22:01 victim1 sshd[123]: Failed password for labuser from 172.20.0.10 port 54321 ssh2

# Successful login after brute-force:
May 13 14:22:15 victim1 sshd[124]: Accepted password for labuser from 172.20.0.10 port 54322 ssh2

# Invalid user (spray attempt):
May 13 14:22:05 victim1 sshd[125]: Invalid user admin from 172.20.0.10 port 54325

# Lateral movement (internal source IP):
May 13 14:25:01 victim3 sshd[200]: Failed password for labuser from 10.10.0.20 port 41234 ssh2
```

---

## Firewall concepts demonstrated

### Network segmentation
The two Docker bridge networks (`172.20.0.0/24` and `10.10.0.0/24`) are completely isolated from each other — containers in Network A cannot reach Network B unless a machine is explicitly connected to both (victim1). This models VLAN-based segmentation in a real enterprise.

### Default-deny vs default-allow
The `firewall_setup.sh hardened` phase demonstrates setting `iptables -P INPUT DROP` — the default-deny model where you must explicitly allow what you want. The `weak` phase is default-allow (common misconfiguration).

### Rate limiting
The `moderate` phase shows the `-m recent` module — tracking connection counts per source IP over a time window. This slows brute-force without blocking legitimate users.

### Logging with iptables
`-j LOG --log-prefix` writes matching packets to syslog. Combining LOG with DROP or ACCEPT creates an audit trail of what the firewall is allowing and blocking.

### Source-based allowlisting
The `hardened` phase only allows SSH from `192.168.100.0/24` (the monitor network), blocking all SSH from the attack network — even if credentials are correct.

---

## Botnet concepts simulated

### Initial access (brute-force)
The `bruteforce` module tries real SSH credential combinations against victim containers. Each failed attempt generates a real entry in `/var/log/auth.log`, just like a real brute-force.

### C2 communication
The `c2` module simulates a bot checking in with its C2 server via HTTP POST at regular intervals. Key concepts:
- **Jitter**: random variation in beacon interval to avoid detection
- **Structured payload**: bot_id, timestamp, task list, exfil status
- **Outbound connections**: beacons are outbound — bypasses most inbound firewalls

### Lateral movement / pivoting
The `lateral` module SSH-connects from the pivot machine (victim1, dual-homed) into Network B. The attacker's traffic appears to originate from `10.10.0.20`, not from `172.20.0.10` — the firewall protecting Network B only sees internal traffic.

### Persistence (conceptual)
The simulator logs persistence-like events (cron, systemd, bashrc modification) as status messages. Implementing real persistence in the lab would require write access to victim filesystems — deliberately not provided.

### Botnet architectures (conceptual)
| Architecture | How it works | Pros for attacker | Pros for defender |
|---|---|---|---|
| Centralized C2 | All bots connect to one server | Simple, fast commands | Disrupt one server = no C2 |
| P2P | Bots relay commands to each other | Resilient to takedown | Much harder to disrupt |
| Domain generation | Bots compute new domain names daily | Hard to preemptively block | Register domains ahead |

---

## Detection techniques

### 1. Threshold-based (SSH-001)
Count events per source IP. If count > N in window T = alert.
Simple, fast, low false positives for SSH.

### 2. Behavioral (SSH-002 password spray)
Look at the *pattern* of failures, not just the count.
Spray: many users, one password. Brute-force: one user, many passwords.

### 3. Correlation (SSH-003)
Correlate two event types: failures + success from same IP.
Neither alone is a certain indicator, but combined they are.

### 4. Topology-based (LATERAL-001)
Use network knowledge: internal-to-internal SSH is unusual.
No need for signatures — the source IP tells you it's suspicious.

### 5. Deception (HONEYPOT-001)
No signature needed — any contact with the honeypot is the alert.
Highest-confidence detection with near-zero false positives.

### 6. Protocol analysis (C2-001)
Look at HTTP headers and payload content for bot fingerprints.
Real C2 uses encrypted channels — this lab uses plaintext for visibility.

---

## How to stop and clean up

```bash
# Stop all containers (preserves built images)
docker compose down

# Stop and remove everything including volumes
docker compose down -v

# Remove built images as well (full reset)
docker compose down --rmi all -v

# Remove any dangling volumes manually
docker volume prune

# Verify nothing is left
docker ps -a | grep -E "attacker|victim|honeypot|monitor"
```

---

## Limitations

| Limitation | Reason | Implication |
|---|---|---|
| No raw socket scanning | Podman rootless blocks raw sockets | Use `-sT` for nmap, or `nc` for port probing |
| No real persistence | Victims have no writable host mounts | Persistence is simulated via log events only |
| Plaintext C2 | Real botnets use TLS/DNS tunneling | Detection is easier than in production |
| Single host | All containers run on one machine | Latency and timing differ from real multi-host networks |
| No IPS enforcement | Suricata rules are provided but not enforced | Rules must be applied manually |
| Simplified passwords | Lab wordlist is tiny vs real rockyou | Real brute-force takes longer |
| No MFA | Lab doesn't test MFA bypass | MFA is the most effective brute-force defense |

---

## Educational notes

### Why weak passwords are dangerous
The lab victim uses `password123`. This password appears in rockyou.txt at position ~400, meaning a real brute-force tool would find it in under a second at 500 attempts/second. The auth.log shows every failed attempt — observing this makes the attack rate viscerally clear.

### Why password auth should be disabled
After running the lab, look at auth.log. The number of failed attempts is the reason production SSH servers should always use `PasswordAuthentication no` and key-based auth only. There is no legitimate reason to keep password auth enabled on internet-facing servers.

### Why segmentation matters
Without the Docker network segmentation, the attacker could reach victim3 directly. With it, the attacker must go through victim1 — and every connection from victim1 to victim3 is logged. Segmentation doesn't stop a determined attacker, but it forces them to leave evidence.

### Why honeypots are high-value
The honeypot generates ZERO false positives. Any connection to `10.10.0.50` is guaranteed to be suspicious because no legitimate user knows it exists. Compare this to a brute-force threshold (which might occasionally alert on a forgetful admin) — the honeypot is absolute.

### The C2 detection problem
The lab C2 uses plaintext HTTP with obvious headers. Real C2 uses TLS-encrypted HTTPS (indistinguishable from normal web traffic by content) or DNS tunneling (hidden in normal DNS queries). This is why behavioral detection (beacon interval regularity, volume anomaly) matters more than content detection for real C2.

### Fail2ban principle
Install fail2ban on the victim (`apt install fail2ban`) and watch it automatically apply iptables rules after 5 failures. This is the simplest automated defense and illustrates the detection-response loop: observe (auth.log) → decide (>5 failures) → respond (ban IP).
