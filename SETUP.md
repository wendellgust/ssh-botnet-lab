# Lab Setup & Run Guide

> FEUP SSR — SSH Botnet Lab · May 2026  
> Educational lab only. All traffic is isolated inside internal Docker/Podman networks.

---

## Prerequisites

Install these on the **Kali machine** that runs the lab.

```bash
# Podman (usually pre-installed on Kali)
podman --version

# Podman compose plugin (required — the old python-podman-compose won't work)
sudo apt install podman-compose          # or:
pip3 install podman-compose

# Verify compose works
podman compose version

# Git (to pull updates from dev machine)
git --version
```

> If you have Docker instead of Podman, everything works the same — the script auto-detects which one is installed.

---

## Repository sync (dev machine → Kali)

All code lives in a git repo. The workflow is:

1. **Dev machine** — edit code, commit, push
2. **Kali** — pull, run

```bash
# On dev machine — after making changes:
git add <changed-files>
git commit -m "describe what changed"
git push

# On Kali — to get the latest version:
cd ~/Downloads/ssh-botnet-lab     # wherever you cloned it
git pull

# Then run the scenario you want to test
./auto_run.sh 3
```

---

## How to run the lab

The entire lab is controlled by one script:

```bash
./auto_run.sh [1|2|3|4]
```

| Argument | Scenario | Networks | What it tests |
|---|---|---|---|
| `1` | Single flat network | attack_net only | Basic SSH brute-force, no segmentation |
| `2` | Two networks, 1 pivot | attack_net + internal_net | Lateral movement via victim1 |
| `3` | Three networks, 2 pivots | + extra_net | Parallel pivots — victim1 and victim2 each control a separate subnet |
| `4` | Three networks, 2-hop chain | + deep_net | Chain: attacker → victim1 → victim3 → victim4 (two hops deep) |

Default (no argument) is scenario 2.

### What the script does automatically

The script runs 8 phases in sequence. You do not need to do anything manually:

```
PHASE 0  — Build images, start containers, wait for sshd
PHASE 1  — Network scan (attacker discovers victim IPs)
PHASE 2  — SSH brute-force on attack_net (victim1, victim2 in parallel)
PHASE 3  — Pivot setup (install paramiko + sim.py on pivot hosts)
PHASE 4  — Lateral movement to internal_net (victim3, honeypot)
PHASE 4b — Deep lateral to extra_net or deep_net (scenarios 3 & 4)
PHASE 5  — C2 beaconing (compromised hosts check in with attacker)
PHASE 6  — IDS analysis (monitor container runs detection rules)
PHASE 7  — Report (summary printed at the end)
```

---

## Expected output per scenario

### Scenario 1

No segmentation — attacker is directly on the same network as all victims.

Expected alerts:
- `SSH-001` — brute-force detected (≥5 failures from same IP)
- `SSH-002` — password spray detected (multiple users, same password pattern)
- `SSH-003` — successful brute-force (failures followed by success from same IP)
- `C2-001` — C2 beacon detected

### Scenario 2

victim1 is dual-homed: it can see both the attack network (172.21.0.x) and the internal network (10.10.x). The attacker brute-forces victim1, then uses victim1 as a stepping stone.

Expected alerts (same as S1, plus):
- `LATERAL-001` — east-west movement (10.10.x.x source connecting to 10.10.x.x target)
- `HONEYPOT-001` — connection to honeypot (10.10.0.50) detected
- `SSH-003` — successful brute-force on victim3 via lateral hop

### Scenario 3

Two independent pivots:
- **victim1** pivots into internal_net (10.10.x)
- **victim2** pivots into extra_net (10.20.x) — attacking victim4 and victim5 in parallel

Expected alerts: all of scenario 2, plus additional LATERAL-001 events from the 10.20.x subnet.

### Scenario 4

Two-hop chain: attacker → victim1 (attack_net) → victim3 (internal_net) → victim4 (deep_net 10.30.x).

Expected alerts: all of scenario 2, plus LATERAL-001 events showing traffic crossing two internal boundaries.

---

## Reading the output

At the end of each run the script prints a detection summary. Key things to look for:

```
IDS ALERTS FIRED:
  SSH-001  SSH Brute-Force Detected          — 2 alerts
  SSH-002  Password Spray Detected           — 1 alert
  SSH-003  Successful Brute-Force            — 2 alerts
  LATERAL-001  East-West Lateral Movement    — 1 alert
  HONEYPOT-001 Honeypot Contact              — 1 alert
  C2-001   C2 Beacon Detected                — 5 alerts
```

If an expected alert is missing, check the lines above it for warnings like:
- `[!] paramiko import failed` — sim.py did not transfer correctly to the pivot
- `[!] victim4 not found` — container name mismatch in the compose file
- `[!] network connect failed` — Podman secondary interface issue (see Troubleshooting)

---

## Inspect logs manually

After a run, you can look inside any container without restarting:

```bash
# Auth log on a victim — every SSH attempt
podman exec victim1 cat /var/log/auth.log

# Honeypot structured events (JSONL format)
podman exec honeypot cat /var/log/lab/honeypot_events.jsonl

# Run the IDS analyzer interactively on the monitor
podman exec -it monitor python3 /lab/analyzer.py

# Check which IPs are visible inside a pivot container
podman exec victim1 ip addr
podman exec victim2 ip addr          # should show both 172.21.x AND 10.20.x
```

---

## Cleanup

```bash
# Stop and remove containers for the current scenario
podman compose --project-directory . -f scenarios/scenario3.yml down

# Stop all scenarios at once
for yml in scenarios/scenario{1,2,3,4}.yml; do
    podman compose --project-directory . -f "$yml" down 2>/dev/null || true
done

# Remove built images (forces full rebuild next time)
podman rmi $(podman images -q) 2>/dev/null || true

# Nuclear option — remove everything Podman knows about
podman system prune -a --volumes
```

---

## Troubleshooting

### "No such file or directory" when building

The build context paths (`./attacker`, `./victim`, etc.) must be resolved from the **lab root directory**, not from `scenarios/`. The script handles this automatically with `--project-directory`. If you run compose manually, always add that flag:

```bash
podman compose --project-directory . -f scenarios/scenario3.yml up -d --build
```

### Build fails with exit code 9 (killed)

Out of memory during parallel build. The script builds services one at a time to avoid this. If it still happens, add swap space:

```bash
sudo fallocate -l 4G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
```

### Scenario 3: victim2 cannot reach victim4/victim5

Podman rootless sometimes attaches a container to a secondary network at the CNI level but does not inject the interface into the container's network namespace. Symptom: `ip addr` inside victim2 shows no 10.20.x.x address.

The script works around this in phase_setup by disconnecting and reconnecting victim2 to extra_net after the containers start. If it still fails:

```bash
# Find the network name
podman network ls | grep extra

# Manually reconnect (replace 'ssh-botnet-lab_extra_net' with the actual name)
podman network disconnect ssh-botnet-lab_extra_net victim2
podman network connect --ip 10.20.0.20 ssh-botnet-lab_extra_net victim2

# Verify
podman exec victim2 ip addr | grep 10.20
```

### sshd not starting inside a container

Check the entrypoint logs:

```bash
podman logs victim4
```

Common cause: host keys not generated. The entrypoint scripts run `ssh-keygen` at startup — this should be automatic.

### "Safety check" blocks a target IP

The simulator refuses to attack IPs outside the lab subnets. If you add new subnets, edit `attacker/simulator.py`:

```python
ALLOWED_NETWORKS = [
    "172.21.0.", "10.10.0.", "10.20.0.", "10.30.0.", "192.168.100."
]
```

### Containers not cleaning up between runs

If `compose down` hangs, kill containers directly:

```bash
podman ps -q | xargs podman stop
podman ps -aq | xargs podman rm
```

---

## Network topology reference

```
SCENARIO 1
  attack_net (172.21.0.0/24)
    attacker  172.21.0.10
    victim1   172.21.0.20
    victim2   172.21.0.21
    monitor   172.21.0.100

SCENARIO 2  (adds internal_net)
  attack_net (172.21.0.0/24)
    attacker  172.21.0.10
    victim1   172.21.0.20  ─── also on internal_net (pivot)
    victim2   172.21.0.21
    monitor   172.21.0.100 ─── also on internal_net
  internal_net (10.10.0.0/24)
    victim1   10.10.0.20   (pivot — dual-homed)
    victim3   10.10.0.10
    honeypot  10.10.0.50
    monitor   10.10.0.100

SCENARIO 3  (adds extra_net via victim2)
  + extra_net (10.20.0.0/24)
    victim2   10.20.0.20   (pivot2 — dual-homed)
    victim4   10.20.0.10
    victim5   10.20.0.11

SCENARIO 4  (deep_net instead of extra_net, 2-hop chain)
  + deep_net  (10.30.0.0/24)
    victim4   10.30.0.10
    victim5   10.30.0.11
    (accessed via victim3 as second pivot, not victim2)
```

---

## Detection rules reference

| Rule ID | Trigger condition | Why it fires |
|---|---|---|
| SSH-001 | ≥ 5 failed SSH logins from same source IP | Classic brute-force threshold |
| SSH-002 | Same source tries ≥ 3 different usernames | Password spray pattern |
| SSH-003 | Source IP has failures then a success | Brute-force that found the password |
| LATERAL-001 | SSH connection where source is an internal IP (10.x) | East-west movement inside a trusted zone |
| HONEYPOT-001 | Any connection attempt to the honeypot IP | Zero false positives — no legitimate user knows it exists |
| C2-001 | HTTP POST with bot-id header to port 8888 | C2 beacon fingerprint |
