#!/bin/bash
# =============================================================================
# SSH Brute-Force & Botnet Lab — Setup Script
# FEUP SSR — Educational use only
# Run this once after cloning: chmod +x setup.sh && ./setup.sh
# =============================================================================

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC}  $1"; }
info() { echo -e "${BLUE}[--]${NC}  $1"; }
warn() { echo -e "${YELLOW}[!!]${NC}  $1"; }
fail() { echo -e "${RED}[ERR]${NC} $1"; exit 1; }
step() { echo -e "\n${CYAN}══ $1 ══${NC}"; }

echo -e "${CYAN}"
cat <<'BANNER'
  ╔═══════════════════════════════════════════════════╗
  ║   SSH Brute-Force & Botnet Lab — Setup Script    ║
  ║   FEUP SSR · Educational Use Only               ║
  ╚═══════════════════════════════════════════════════╝
BANNER
echo -e "${NC}"

# =============================================================================
# Step 1 — Detect container runtime
# =============================================================================
step "Step 1 — Detect container runtime"

EXE=""
COMPOSE=""

if command -v podman &>/dev/null; then
  ok "Found: podman $(podman --version | awk '{print $3}')"
  EXE="podman"
  systemctl --user start podman.socket 2>/dev/null || true
  systemctl --user enable podman.socket 2>/dev/null || true
  if command -v docker-compose &>/dev/null; then
    COMPOSE="docker-compose"
  elif docker compose version &>/dev/null 2>&1; then
    COMPOSE="docker compose"
  else
    fail "No compose provider. Run: sudo apt install docker-compose-plugin"
  fi
elif command -v docker &>/dev/null; then
  ok "Found: docker"
  EXE="docker"
  COMPOSE="docker compose"
else
  fail "Install podman: sudo apt install podman"
fi
ok "Compose: $COMPOSE"

# =============================================================================
# Step 2 — Remove old containers and networks
# =============================================================================
step "Step 2 — Clean up old containers and networks"

for c in attacker victim1 victim2 victim3 honeypot monitor; do
  $EXE rm -f $c 2>/dev/null && info "Removed: $c" || true
done

for n in $(echo \
  "ssh-botnet-lab_attack_net ssh-botnet-lab_internal_net \
   lab-github_attack_net lab-github_internal_net \
   dokcer_botnet-lab ssh-botnet-lab_monitor-net"); do
  $EXE network rm $n 2>/dev/null && info "Removed network: $n" || true
done
ok "Cleanup done"

# =============================================================================
# Step 3 — Build images and start containers
# =============================================================================
step "Step 3 — Build and start containers (2–4 min first run)"

$COMPOSE up -d --build

info "Waiting 6 seconds for containers to initialise..."
sleep 6

ALL_UP=true
for c in attacker victim1 victim2 victim3 honeypot monitor; do
  S=$($EXE inspect --format='{{.State.Status}}' $c 2>/dev/null || echo "missing")
  if [ "$S" = "running" ]; then ok "$c is running"
  else warn "$c status: $S"; ALL_UP=false; fi
done

if [ "$ALL_UP" = false ]; then
  warn "Some containers failed. Check: $EXE logs victim1"
  warn "Continuing anyway..."
fi

# =============================================================================
# Step 4 — Verify SSH is working on all victims
# =============================================================================
step "Step 4 — Verify SSH on victims"

for c in victim1 victim2 victim3 honeypot; do
  if $EXE inspect --format='{{.State.Status}}' $c 2>/dev/null | grep -q running; then
    LOG=$($EXE exec $c cat /var/log/auth.log 2>/dev/null | head -5 || echo "")
    if echo "$LOG" | grep -q "Server listening"; then
      ok "SSH listening on $c"
    else
      warn "$c sshd may not be running — checking..."
      $EXE exec $c bash -c "
        mkdir -p /run/sshd
        ssh-keygen -A 2>/dev/null
        pkill -x sshd 2>/dev/null || true
        sleep 1
        /usr/sbin/sshd -D -e 2>> /var/log/auth.log &
        sleep 2
        ss -tlnp | grep 22 | head -1
      " && ok "sshd restarted on $c" || warn "Could not restart sshd on $c"
    fi
  fi
done

# =============================================================================
# Step 5 — Copy paramiko to victim1 for lateral movement
# =============================================================================
step "Step 5 — Copy Python libraries to victim1"

if $EXE inspect --format='{{.State.Status}}' attacker 2>/dev/null | grep -q running && \
   $EXE inspect --format='{{.State.Status}}' victim1  2>/dev/null | grep -q running; then

  # Check if paramiko already works
  ALREADY=$($EXE exec victim1 python3 -c "import paramiko; print('ok')" 2>/dev/null || echo "no")
  if [ "$ALREADY" = "ok" ]; then
    ok "paramiko already available on victim1"
  else
    info "Copying Python packages from attacker to victim1..."
    $EXE exec attacker bash -c \
      "tar czf /tmp/pypkgs.tar.gz /usr/lib/python3/dist-packages/ 2>/dev/null; echo done"
    $EXE exec attacker bash -c \
      "tar czf /tmp/libs.tar.gz \
        /usr/lib/x86_64-linux-gnu/libsodium* \
        /usr/lib/x86_64-linux-gnu/libcrypto* \
        /usr/lib/x86_64-linux-gnu/libssl* 2>/dev/null; echo done"

    $EXE cp attacker:/tmp/pypkgs.tar.gz /tmp/pypkgs_lab.tar.gz
    $EXE cp attacker:/tmp/libs.tar.gz   /tmp/libs_lab.tar.gz
    $EXE cp /tmp/pypkgs_lab.tar.gz victim1:/tmp/pypkgs.tar.gz
    $EXE cp /tmp/libs_lab.tar.gz   victim1:/tmp/libs.tar.gz
    $EXE exec victim1 bash -c "cd / && tar xzf /tmp/pypkgs.tar.gz 2>/dev/null; echo ok"
    $EXE exec victim1 bash -c "cd / && tar xzf /tmp/libs.tar.gz   2>/dev/null; echo ok"
    $EXE exec victim1 ldconfig 2>/dev/null || true

    RESULT=$($EXE exec victim1 python3 -c "import paramiko; print('ok')" 2>/dev/null || echo "fail")
    if [ "$RESULT" = "ok" ]; then ok "paramiko works on victim1"
    else warn "paramiko failed — lateral movement phase may not work"; fi
  fi
else
  warn "Skipping paramiko copy — containers not ready"
fi

# =============================================================================
# Step 6 — Deploy simulator to victim1 with updated wordlist
# =============================================================================
step "Step 6 — Deploy simulator to victim1"

if $EXE inspect --format='{{.State.Status}}' attacker 2>/dev/null | grep -q running && \
   $EXE inspect --format='{{.State.Status}}' victim1  2>/dev/null | grep -q running; then

  $EXE cp attacker:/lab/simulator.py /tmp/sim_lab.py

  python3 -c "
c = open('/tmp/sim_lab.py').read()
if 'internal123' not in c:
    c = c.replace(
        '\"pass1234\"',
        '\"pass1234\", \"internal123\", \"service1\", \"rootpass\"'
    )
    open('/tmp/sim_lab.py','w').write(c)
    print('wordlist updated')
else:
    print('wordlist already has internal passwords')
"
  $EXE cp /tmp/sim_lab.py victim1:/tmp/sim.py
  ok "Simulator deployed to victim1"
else
  warn "Skipping — containers not ready"
fi

# =============================================================================
# Step 7 — Fix analyzer regex (sshd -e has no syslog prefix)
# =============================================================================
step "Step 7 — Fix analyzer log format"

if $EXE inspect --format='{{.State.Status}}' monitor 2>/dev/null | grep -q running; then
  $EXE cp monitor:/lab/monitor/analyzer.py /tmp/analyzer_lab.py

  python3 << 'PYEOF'
c = open('/tmp/analyzer_lab.py').read()
fixes = [
    (
        'r"(?P<ts>\\w+ +\\d+ [\\d:]+) .*sshd.* "\n    r"Failed password for (?:invalid user )?(?P<user>\\S+) "\n    r"from (?P<src_ip>[\\d.]+) port (?P<src_port>\\d+)"',
        'r"Failed password for (?:invalid user )?(?P<user>\\S+) from (?P<src_ip>[\\d.]+) port (?P<src_port>\\d+)"'
    ),
    (
        'r"(?P<ts>\\w+ +\\d+ [\\d:]+) .*sshd.* "\n    r"Accepted password for (?P<user>\\S+) "\n    r"from (?P<src_ip>[\\d.]+) port (?P<src_port>\\d+)"',
        'r"Accepted password for (?P<user>\\S+) from (?P<src_ip>[\\d.]+) port (?P<src_port>\\d+)"'
    ),
    (
        'r"(?P<ts>\\w+ +\\d+ [\\d:]+) .*sshd.* "\n    r"Invalid user (?P<user>\\S+) from (?P<src_ip>[\\d.]+)"',
        'r"Invalid user (?P<user>\\S+) from (?P<src_ip>[\\d.]+)"'
    ),
]
changed = sum(1 for old, new in fixes if old in c and c.count(old) > 0)
for old, new in fixes:
    c = c.replace(old, new)
open('/tmp/analyzer_lab.py','w').write(c)
print(f'Analyzer patched ({changed} patterns updated)')
PYEOF

  $EXE cp /tmp/analyzer_lab.py monitor:/lab/monitor/analyzer.py
  ok "Analyzer regex fixed"
else
  warn "Skipping — monitor not running"
fi

# =============================================================================
# Step 8 — Final SSH connectivity test
# =============================================================================
step "Step 8 — Final connectivity test"

sleep 2
TEST=$($EXE exec attacker bash -c \
  "ssh -o StrictHostKeyChecking=no \
       -o PasswordAuthentication=yes \
       -o PubkeyAuthentication=no \
       -o BatchMode=no \
       -o ConnectTimeout=5 \
       labuser@172.21.0.20 'echo connected' 2>&1" || echo "FAIL")

if echo "$TEST" | grep -q "connected"; then
  ok "SSH login to victim1 confirmed — lab is fully working"
elif echo "$TEST" | grep -q "Permission denied"; then
  ok "SSH is responding on victim1 (auth working)"
else
  warn "SSH test inconclusive: $TEST"
  warn "Try manually: podman exec -it attacker ssh labuser@172.21.0.20"
  warn "(password: password123)"
fi

# =============================================================================
# Done
# =============================================================================
echo ""
echo -e "${GREEN}"
cat <<'DONE'
  ╔═══════════════════════════════════════════════════╗
  ║              LAB SETUP COMPLETE                  ║
  ╚═══════════════════════════════════════════════════╝
DONE
echo -e "${NC}"

echo "  Quick start — open 3 terminals:"
echo ""
echo "  Terminal 1:"
echo "    $EXE exec -it victim1 tail -f /var/log/auth.log"
echo ""
echo "  Terminal 2:"
echo "    $EXE exec -it attacker python3 /lab/simulator.py bruteforce --target 172.21.0.20 --delay 1.0 --max-attempts 150"
echo ""
echo "  Terminal 3 (after attack):"
echo "    $EXE exec victim1 cat /var/log/auth.log > /tmp/auth.log && $EXE cp /tmp/auth.log monitor:/var/log/lab/auth.log"
echo "    $EXE exec -it monitor python3 /lab/monitor/analyzer.py --report"
echo ""
echo "  Full guide: docs/LAB_GUIDE.md"
echo ""
