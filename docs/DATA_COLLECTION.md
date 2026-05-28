# Data Collection Guide — SSH Botnet Lab
**FEUP SSR | What to capture and where to find it**

---

## Overview

This guide lists every piece of data worth capturing for your report, the exact command to get it, and what to look for in the output. Run each scenario at least once, collect the data listed below, and paste the relevant sections into your report.

---

## 1. GUI Report (fastest summary)

Start the GUI and run a scenario. When the botnet finishes, click **📋 Report**.

What to capture:
- Screenshot of the **Summary** stat grid (hosts found / compromised / networks)
- Screenshot of the **Host Details** table — shows IPs, credentials, and pivot chain
- Screenshot of the **Infection Chain** — shows propagation path graphically
- Screenshot of the **Simulated IDS Alerts** section

Copy the raw JSON directly:
```bash
curl -s http://localhost:5000/report | python3 -m json.tool
```

Save it:
```bash
curl -s http://localhost:5000/report > report_data.json
```

The JSON contains every field the report modal shows, including credentials found and pivot paths.

---

## 2. Botnet Live Output

Capture the full botnet output to a file while it runs:

```bash
# Run attacker container and save output
podman exec -it attacker python3 /lab/botnet.py 2>&1 | tee botnet_run.log
```

Lines to highlight in your report:

| Line pattern | What it means |
|---|---|
| `[ATTACK] Trying user:pass on X.X.X.X` | Brute-force attempt in progress |
| `[OK] Compromised X.X.X.X — user:pass` | Successful credential match |
| `[PIVOT] Scanning network 10.X.X.0/24 via X.X.X.X` | Lateral movement scan |
| `[PIVOT] New network discovered: 10.X.0.0/24` | New subnet found through pivot |
| `[C2] Beacon from X.X.X.X seq=N` | Bot checking in to command-and-control |

Count and report:
- Total brute-force attempts (count `[ATTACK]` lines)
- Success rate: compromised / total unique targets
- Number of networks discovered automatically

```bash
grep -c "\[ATTACK\]" botnet_run.log   # total attempts
grep -c "\[OK\]" botnet_run.log       # successful compromises
grep -c "\[PIVOT\]" botnet_run.log    # pivot events
grep "\[OK\]" botnet_run.log          # list all compromised hosts + credentials
```

---

## 3. SSH Authentication Logs (victim side)

These logs are what a defender would see. They are the primary evidence of a brute-force attack.

```bash
# victim1 — always reachable directly
podman exec victim1 cat /var/log/auth.log > victim1_auth.log

# victim3 — inside internal network
podman exec victim3 cat /var/log/auth.log > victim3_auth.log

# All victims at once
for v in victim1 victim2 victim3 victim4 victim5; do
  podman exec $v cat /var/log/auth.log 2>/dev/null > ${v}_auth.log && echo "$v: done" || echo "$v: not running"
done
```

Key patterns to extract and count:

```bash
# Count failed login attempts (per victim)
grep -c "Failed password" victim1_auth.log

# List every username tried
grep "Failed password" victim1_auth.log | awk '{print $9}' | sort | uniq -c | sort -rn

# List every source IP seen
grep "Failed password" victim1_auth.log | awk '{print $11}' | sort | uniq -c

# Show successful logins
grep "Accepted password" victim1_auth.log

# Show when the attack started and ended (timestamps)
grep "Failed password" victim1_auth.log | head -1   # first attempt
grep "Failed password" victim1_auth.log | tail -1   # last attempt
```

For a table in your report, this command prints a clean summary:

```bash
for v in victim1 victim2 victim3 victim4 victim5; do
  total=$(grep -c "Failed password" ${v}_auth.log 2>/dev/null || echo 0)
  success=$(grep -c "Accepted password" ${v}_auth.log 2>/dev/null || echo 0)
  echo "$v: $total failed, $success accepted"
done
```

---

## 4. Network Discovery Data

What networks the botnet discovered through pivoting:

```bash
# From the botnet log
grep "New network discovered" botnet_run.log

# From each compromised host — what routes it can see
podman exec victim1 ip route
podman exec victim3 ip route    # pivot host — should show internal_net
```

For Scenario 4 (deep chain), victim3 is the second pivot:
```bash
podman exec victim3 ip route    # can reach deep_net (10.30.x.x)
```

Paste the `ip route` output to show which hosts are dual-homed (connected to multiple networks), since those are what make pivoting possible.

---

## 5. C2 Beacon Data

Victims send HTTP beacons to the attacker on port 8888. Capture them:

```bash
# On the attacker container — watch incoming beacons live
podman exec attacker bash -c "nc -l -p 8888 -k" &

# Or capture with tcpdump on the attacker's interface
podman exec attacker tcpdump -i eth0 -A port 8888 -c 20 2>/dev/null
```

The JSON beacon format is:
```json
{"bot_id": "victim1", "type": "HEARTBEAT", "seq": 3, "ts": 1234567890}
```

For deeper network bots (victim3, victim4) that cannot reach the attacker directly, beacons relay through victim1 on port 8889. Capture the relay:

```bash
podman exec victim1 tcpdump -i any port 8889 -c 10 -A 2>/dev/null
```

This demonstrates the **tiered C2 architecture** — a key concept to explain in your report.

---

## 6. Wordlist Statistics

The brute-force uses a wordlist. Show its size and what was in it:

```bash
# Count entries in the wordlist
podman exec attacker wc -l /lab/wordlist.txt

# Show first 20 entries
podman exec attacker head -20 /lab/wordlist.txt

# Show which credential actually worked (from botnet log)
grep "\[OK\]" botnet_run.log | awk -F'— ' '{print $2}'
```

Calculate the position of the correct credential:
```bash
# e.g. if correct password is "toor"
grep -n "toor" <(podman exec attacker cat /lab/wordlist.txt) | head -5
```

This shows how many attempts were needed before success — relevant for discussing attack efficiency.

---

## 7. Defense Effectiveness Data

Run the attack, then apply a defense from the GUI **Defenses** panel, then run again. Compare the logs.

### fail2ban

```bash
# Apply from GUI → Defenses → fail2ban → victim1
# Then run the botnet again and check:
podman exec victim1 fail2ban-client status sshd

# Expected output shows: currently banned IPs, total ban count
```

Copy the `fail2ban-client status sshd` output into your report — it shows exactly how many bans were triggered.

```bash
# Also check fail2ban log
podman exec victim1 cat /var/log/fail2ban.log
```

### Block Attacker IP (iptables)

```bash
# Apply from GUI → Defenses → Block Attacker IP → victim1
# Verify the rule is in place:
podman exec victim1 iptables -L INPUT -n -v

# Check the packet counter — it increments as the botnet hits the block
podman exec victim1 iptables -L INPUT -n -v | grep "172.21.0.10"
```

The packet counter (first column) proves traffic was blocked. Capture before and after screenshots.

### SSH Rate Limit

```bash
# After applying rate limit:
podman exec victim1 iptables -L INPUT -n -v | grep -A2 "recent"

# The botnet log will show many more timeouts/failures
grep "timed out\|Connection refused" botnet_run.log | wc -l
```

### Disable Password Auth

```bash
# After applying:
podman exec victim1 cat /etc/ssh/sshd_config | grep PasswordAuthentication

# The botnet will immediately stop being able to authenticate
# Botnet log will show: authentication failed (even with correct password)
```

---

## 8. Scenario Comparison Table

Run all four scenarios and fill in this table for your report:

| Scenario | Topology | Hosts | Compromised | Networks | Pivots |
|---|---|---|---|---|---|
| 1 — Single Net | Flat | 3 | ? | 1 | 0 |
| 2 — Two Nets | Segmented | 4 | ? | 2 | 1 |
| 3 — Three Nets | Two pivots | 6 | ? | 3 | 2 |
| 4 — Deep Chain | Three hops | 6 | ? | 3 | 2 |

Get each row's numbers from the GUI Report modal after running the scenario.

---

## 9. Packet-Level Evidence (optional but strong)

Capture actual SSH packets during the attack:

```bash
# On the host machine — capture traffic to victim1 port 22
# Find the victim1 container IP first:
podman inspect victim1 | grep '"IPAddress"'

# Then capture (requires tcpdump on host or inside container)
podman exec victim1 tcpdump -i eth0 -c 50 port 22 -w /tmp/ssh_attack.pcap

# Copy pcap to host
podman cp victim1:/tmp/ssh_attack.pcap ./ssh_attack.pcap

# Open in Wireshark or summarize:
tcpdump -r ssh_attack.pcap -n | head -30
```

The pcap shows the rapid connection burst pattern characteristic of brute-force.

---

## 10. Quick Data Capture Script

Run this after a botnet run to collect everything at once:

```bash
#!/bin/bash
OUT="lab_data_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT"

# Botnet report JSON
curl -s http://localhost:5000/report > "$OUT/report.json"

# Auth logs from all victims
for v in victim1 victim2 victim3 victim4 victim5; do
  podman exec $v cat /var/log/auth.log 2>/dev/null > "$OUT/${v}_auth.log" || true
done

# Network routes (show dual-homed hosts)
for v in victim1 victim2 victim3 victim4 victim5; do
  podman exec $v ip route 2>/dev/null > "$OUT/${v}_routes.txt" || true
done

# Container IPs and network memberships
podman network ls > "$OUT/networks.txt"
for v in attacker victim1 victim2 victim3 victim4 victim5; do
  podman inspect $v 2>/dev/null | python3 -c "
import sys,json; d=json.load(sys.stdin)[0]
nets = d['NetworkSettings']['Networks']
for n,info in nets.items(): print(f'  {n}: {info[\"IPAddress\"]}')
" | sed "1s/^/$v:\n/" >> "$OUT/networks.txt" || true
done

echo "Data saved to $OUT/"
ls -lh "$OUT/"
```

Save this as `collect_data.sh` and run it with `bash collect_data.sh` after each scenario.
