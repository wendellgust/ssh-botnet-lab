# SSH Brute-Force & Botnet Lab

> **Educational use only — FEUP SSR Cybersecurity Research Lab**  
> All traffic runs inside isolated Docker/Podman networks with no internet access.

---

## What this lab does

This lab simulates the full lifecycle of a botnet attack in a safe, isolated environment:

| Phase | What happens |
|---|---|
| Reconnaissance | Port scan to discover SSH targets |
| Brute-force | Automated SSH credential attacks |
| Lateral movement | Pivot through compromised machine into segmented network |
| C2 beaconing | Infected machines phone home to command-and-control |
| Detection | Log analysis and IDS rules identify the attack |
| Hardening | Firewall rules, SSH keys, and fail2ban stop the attack |

## Architecture

```
attack_net (172.21.0.0/24) — isolated, no internet
┌─────────────┐   brute-force   ┌─────────────┐   scan   ┌─────────────┐
│  Attacker   │ ──────────────► │  Victim 1   │          │  Victim 2   │
│ 172.21.0.10 │                 │ 172.21.0.20 │          │ 172.21.0.21 │
└─────────────┘                 │ pivot point │          └─────────────┘
                                └──────┬──────┘
                                       │ lateral movement
                          ─────────────▼──────────────────────
                          internal_net (10.10.0.0/24)
                          ┌─────────────┐   ┌─────────────┐
                          │  Victim 3   │   │  Honeypot   │
                          │ 10.10.0.10  │   │ 10.10.0.50  │
                          └─────────────┘   └─────────────┘
```

## Requirements

- **Linux** (tested on Kali Linux)
- **Podman** (recommended) or **Docker**
- **Podman Compose** or **Docker Compose**
- 4 GB RAM minimum
- 5 GB free disk space

```bash
# Install on Kali / Debian / Ubuntu
sudo apt update
sudo apt install -y podman podman-compose
```

---

## Quick setup — one command

```bash
git clone <your-repo-url>
cd ssh-botnet-lab
chmod +x setup.sh
./setup.sh
```

The setup script will:
- Detect Podman or Docker automatically
- Remove any conflicting old networks
- Build and start all 6 containers
- Apply all required fixes (MaxStartups, paramiko, analyzer)
- Verify SSH is working
- Print the commands to start testing

---

## Manual setup (if setup.sh fails)

### 1. Start containers

```bash
podman compose up -d --build
podman ps   # verify 6 containers are Up
```

### 2. Apply MaxStartups fix (prevents SSH throttling)

```bash
for c in victim1 victim2 victim3 honeypot; do
  podman exec $c bash -c "echo 'MaxStartups 50' >> /etc/ssh/sshd_config && kill -HUP 1"
done
```

### 3. Copy paramiko to victim1 (needed for lateral movement)

```bash
podman exec attacker bash -c "tar czf /tmp/pypkgs.tar.gz /usr/lib/python3/dist-packages/"
podman cp attacker:/tmp/pypkgs.tar.gz /tmp/pypkgs.tar.gz
podman cp /tmp/pypkgs.tar.gz victim1:/tmp/pypkgs.tar.gz
podman exec victim1 bash -c "cd / && tar xzf /tmp/pypkgs.tar.gz"

podman exec attacker bash -c "tar czf /tmp/libs.tar.gz \
  /usr/lib/x86_64-linux-gnu/libsodium* \
  /usr/lib/x86_64-linux-gnu/libcrypto* \
  /usr/lib/x86_64-linux-gnu/libssl* 2>/dev/null"
podman cp attacker:/tmp/libs.tar.gz /tmp/libs.tar.gz
podman cp /tmp/libs.tar.gz victim1:/tmp/libs.tar.gz
podman exec victim1 bash -c "cd / && tar xzf /tmp/libs.tar.gz"
podman exec victim1 ldconfig
podman exec victim1 python3 -c "import paramiko; print('ok')"
```

### 4. Deploy simulator to victim1

```bash
podman cp attacker:/lab/simulator.py /tmp/sim.py
# Add internal network passwords
python3 -c "
c=open('/tmp/sim.py').read()
c=c.replace('\"pass1234\"','\"pass1234\", \"internal123\", \"service1\"')
open('/tmp/sim.py','w').write(c)"
podman cp /tmp/sim.py victim1:/tmp/sim.py
```

---

## Running the lab

See **[docs/LAB_GUIDE.md](docs/LAB_GUIDE.md)** for the full step-by-step guide.

### Quick test

```bash
# Terminal 1 — watch victim logs
podman exec -it victim1 tail -f /var/log/auth.log

# Terminal 2 — run brute-force
podman exec -it attacker python3 /lab/simulator.py bruteforce \
  --target 172.21.0.20 --delay 1.0 --max-attempts 150

# Terminal 3 — collect logs and run detection
podman exec victim1 cat /var/log/auth.log > /tmp/auth.log
podman cp /tmp/auth.log monitor:/var/log/lab/auth.log
podman exec -it monitor python3 /lab/monitor/analyzer.py --report
```

### Available simulator commands

```bash
# From attacker container
python3 /lab/simulator.py scan        --network 172.21.0.
python3 /lab/simulator.py bruteforce  --target 172.21.0.20 --delay 1.0 --max-attempts 150
python3 /lab/simulator.py c2          --c2-host 172.21.0.10 --count 5
python3 /lab/simulator.py botnet      # full scenario

# From victim1 (lateral movement)
python3 /tmp/sim.py bruteforce --target 10.10.0.10 --delay 1.0 --max-attempts 120
```

### Lab credentials

| Container | Username | Password |
|---|---|---|
| victim1, victim2 | labuser | password123 |
| victim1, victim2 | admin | admin |
| victim3, honeypot | labuser | internal123 |
| victim3, honeypot | svcaccount | service1 |

---

## File structure

```
ssh-botnet-lab/
├── setup.sh                    ← run this first
├── docker-compose.yml          ← lab topology
├── attacker/
│   ├── Dockerfile
│   ├── entrypoint.sh
│   └── simulator.py            ← botnet simulation engine
├── victim/                     ← Network A victims
│   ├── Dockerfile
│   ├── entrypoint.sh
│   └── firewall_setup.sh       ← iptables demo (weak/moderate/hardened)
├── victim-b/                   ← Network B victims + honeypot
│   ├── Dockerfile
│   ├── entrypoint.sh
│   └── honeypot_logger.py
├── monitor/
│   ├── Dockerfile
│   ├── entrypoint.sh
│   ├── analyzer.py             ← detection engine (6 rules)
│   └── rules/
│       └── ssh_botnet.rules    ← Suricata/Snort rules
└── docs/
    ├── LAB_GUIDE.md            ← full step-by-step guide
    └── explainSSR.txt          ← deep-dive explanation of all concepts
```

---

## Clean up

```bash
# Stop containers
podman compose down

# Full reset
podman compose down --rmi all
podman network prune -f
```

---

## Known issues and fixes

| Issue | Fix |
|---|---|
| `SSHException: Error reading SSH protocol banner` | Run setup.sh — it applies MaxStartups 50 automatically |
| `Network is unreachable` from attacker to 10.10.0.x | Expected — lateral movement must run FROM victim1 |
| Analyzer shows 0 events | Copy logs first: `podman exec victim1 cat /var/log/auth.log > /tmp/auth.log` |
| Subnet conflict on startup | setup.sh removes old networks automatically |
| `chroot /run/sshd: Operation not permitted` | Fixed in entrypoint.sh — removed /run/sshd creation |

---

*FEUP SSR · May 2026 · All traffic isolated · No internet access*
