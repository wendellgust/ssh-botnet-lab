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

> **Note:** `botnet.py` (the autonomous botnet) does not send C2 beacons — it focuses on propagation. C2 data below requires the **manual approach from POLO.md Phase 5**.

Start a listener on the attacker, then send beacons manually from the victim containers:

**Terminal 1 — C2 listener on attacker:**
```bash
podman exec -it attacker python3 -c "
import socket, json
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(('0.0.0.0', 8888)); srv.listen(10)
print('[C2] Listener ready on port 8888')
while True:
    conn, addr = srv.accept()
    data = conn.recv(1024).decode(errors='ignore')
    print(f'[C2] BEACON from {addr[0]}: {data[:120]}')
    conn.send(b'HTTP/1.1 200 OK\r\n\r\nOK'); conn.close()
"
```

**Terminal 2 — send beacons from victim1:**
```bash
podman exec -it victim1 python3 -c "
import socket, time, json
from datetime import datetime
for i in range(5):
    payload = json.dumps({'bot_id':'victim1','type':'HEARTBEAT','seq':i+1,
                          'ts':datetime.utcnow().isoformat()}).encode()
    s = socket.create_connection(('172.21.0.10', 8888), timeout=3)
    s.send(b'POST /beacon HTTP/1.1\r\nContent-Length: ' + str(len(payload)).encode() + b'\r\n\r\n' + payload)
    s.close(); print(f'Beacon {i+1}/5 sent'); time.sleep(5)
"
```

The JSON beacon format you will see in the listener output:
```json
{"bot_id": "victim1", "type": "HEARTBEAT", "seq": 3, "ts": "2026-05-25T10:00:00"}
```

**victim3 cannot beacon directly to the attacker** (no route). It beacons to victim1 (10.10.0.20), which relays. This is the tiered C2 architecture — a key concept to explain in your report. Use 10.10.0.20 as the target from victim3 and set up a relay listener on victim1 port 8889 (see POLO.md Phase 5 Step 3 for the exact relay code).

---

## 6. Credential List Statistics

The botnet's credentials are defined as Python lists inside `botnet.py` (not a separate file). Extract them:

```bash
# Show all usernames and passwords tried
podman exec attacker python3 -c "
import re
src = open('/lab/botnet.py').read()
users = re.search(r'USERNAMES\s*=\s*(\[.*?\])', src, re.S).group(1)
pwds  = re.search(r'PASSWORDS\s*=\s*(\[.*?\])', src, re.S).group(1)
import ast
u = ast.literal_eval(users); p = ast.literal_eval(pwds)
print(f'Usernames ({len(u)}): {u}')
print(f'Passwords ({len(p)}): {p}')
print(f'Total combinations: {len(u)*len(p)}')
"
```

Show which credential actually worked (from botnet log):
```bash
grep "✓\|Compromised\|\[OK\]" botnet_run.log
```

Find where in the list the successful password appears:
```bash
# Run after a botnet run — reads the compromised host's credential from the log
grep "✓" botnet_run.log | head -5
```

This shows how many attempts were needed before the first success — the metric that shows why longer/unique passwords matter.

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
| 3 — Three Nets | Two pivots | 5 | ? | 3 | 2 |
| 4 — Deep Chain | Three hops | 5 | ? | 3 | 2 |

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

`collect_data.sh` is included at the project root. Run it after any scenario:

```bash
# Collect data for scenario 2
bash collect_data.sh 2

# Creates a timestamped folder: lab_data_S2_20260525_143022/
#   gui_report.json      — full JSON from the GUI Report modal
#   victim1_auth.log     — SSH auth log from victim1
#   victim2_auth.log     — etc.
#   victim3_auth.log
#   honeypot_auth.log
#   victimN_routes.txt   — ip route output (shows dual-homed pivot hosts)
#   container_ips.txt    — all container IPs and network memberships
#   credential_list.txt  — usernames/passwords tried and total combinations
#   summary.txt          — failed/accepted counts per victim, top attacker IPs
```

Run this after each of the 4 scenarios and you will have all the raw data needed for the comparison table in Section 8.
