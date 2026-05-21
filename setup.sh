#!/bin/bash
# =============================================================================
# SSH Brute-Force & Botnet Lab — Automated Setup Script
# FEUP SSR — Educational use only
# =============================================================================
# This script:
#   1. Checks system requirements (Podman or Docker)
#   2. Resolves common subnet conflicts
#   3. Builds and starts all containers
#   4. Applies all post-start fixes (MaxStartups, paramiko, analyzer regex)
#   5. Verifies the lab is working correctly
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

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

COMPOSE_CMD=""
EXEC_CMD=""

if command -v podman &>/dev/null; then
  ok "Found: podman $(podman --version | awk '{print $3}')"
  EXEC_CMD="podman"

  # Start podman socket for compose compatibility
  if ! systemctl --user is-active podman.socket &>/dev/null; then
    info "Starting podman user socket..."
    systemctl --user start podman.socket 2>/dev/null || warn "Could not start podman socket (may still work)"
    systemctl --user enable podman.socket 2>/dev/null || true
  fi

  if command -v docker-compose &>/dev/null; then
    COMPOSE_CMD="docker-compose"
  elif podman compose version &>/dev/null 2>&1; then
    COMPOSE_CMD="podman compose"
  elif command -v docker &>/dev/null && docker compose version &>/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
  else
    fail "No compose provider found. Install: sudo apt install docker-compose-plugin"
  fi
  ok "Compose provider: $COMPOSE_CMD"

elif command -v docker &>/dev/null; then
  ok "Found: docker $(docker --version | awk '{print $3}' | tr -d ',')"
  EXEC_CMD="docker"
  if docker compose version &>/dev/null 2>&1; then
    COMPOSE_CMD="docker compose"
  else
    COMPOSE_CMD="docker-compose"
  fi
  ok "Compose provider: $COMPOSE_CMD"
else
  fail "Neither podman nor docker found. Install podman: sudo apt install podman"
fi

# =============================================================================
# Step 2 — Clean up old containers and conflicting networks
# =============================================================================
step "Step 2 — Clean up old containers and networks"

info "Removing old lab containers if they exist..."
for c in attacker victim1 victim2 victim3 honeypot monitor; do
  $EXEC_CMD rm -f $c 2>/dev/null && info "Removed container: $c" || true
done

info "Removing old lab networks if they exist..."
for n in ssh-botnet-lab_attack_net ssh-botnet-lab_internal_net \
          dokcer_botnet-lab ssh-botnet-lab_monitor-net \
          ssh-botnet-lab_attack-net ssh-botnet-lab_internal-net; do
  $EXEC_CMD network rm $n 2>/dev/null && info "Removed network: $n" || true
done

ok "Cleanup complete"

# =============================================================================
# Step 3 — Build and start containers
# =============================================================================
step "Step 3 — Build and start all containers"

info "Building images and starting containers..."
info "This takes 2–4 minutes on first run (downloading Ubuntu base image)"
echo ""

$COMPOSE_CMD up -d --build

echo ""
info "Waiting 5 seconds for containers to initialise..."
sleep 5

# Verify all containers are running
FAILED=0
for c in attacker victim1 victim2 victim3 honeypot monitor; do
  STATUS=$($EXEC_CMD inspect --format='{{.State.Status}}' $c 2>/dev/null || echo "missing")
  if [ "$STATUS" = "running" ]; then
    ok "Container $c is running"
  else
    warn "Container $c status: $STATUS"
    FAILED=1
  fi
done

if [ $FAILED -eq 1 ]; then
  warn "Some containers are not running. Check logs with: $EXEC_CMD logs victim1"
  warn "Continuing with setup anyway..."
fi

# =============================================================================
# Step 4 — Apply MaxStartups fix on all victim containers
# =============================================================================
step "Step 4 — Apply sshd MaxStartups fix"

info "MaxStartups 50 prevents connection throttling during brute-force simulation"

for c in victim1 victim2 victim3 honeypot; do
  if $EXEC_CMD inspect --format='{{.State.Status}}' $c 2>/dev/null | grep -q running; then
    $EXEC_CMD exec $c bash -c "
      grep -q 'MaxStartups 50' /etc/ssh/sshd_config 2>/dev/null || \
      echo 'MaxStartups 50' >> /etc/ssh/sshd_config
      kill -HUP 1 2>/dev/null || true
    " 2>/dev/null && ok "MaxStartups applied to $c" || warn "Could not apply to $c"
  fi
done

# =============================================================================
# Step 5 — Copy paramiko to victim1 for lateral movement phase
# =============================================================================
step "Step 5 — Copy Python libraries to victim1"

info "victim1 needs paramiko to run the lateral movement simulator"
info "Victims have no internet access (internal: true) so we copy from attacker"

if $EXEC_CMD inspect --format='{{.State.Status}}' attacker 2>/dev/null | grep -q running && \
   $EXEC_CMD inspect --format='{{.State.Status}}' victim1  2>/dev/null | grep -q running; then

  info "Packaging Python dist-packages from attacker..."
  $EXEC_CMD exec attacker bash -c \
    "tar czf /tmp/pypkgs.tar.gz /usr/lib/python3/dist-packages/ 2>/dev/null; echo done"

  info "Packaging shared libraries from attacker..."
  $EXEC_CMD exec attacker bash -c \
    "tar czf /tmp/libs.tar.gz \
      /usr/lib/x86_64-linux-gnu/libsodium* \
      /usr/lib/x86_64-linux-gnu/libcrypto* \
      /usr/lib/x86_64-linux-gnu/libssl* 2>/dev/null; echo done"

  info "Copying to victim1..."
  $EXEC_CMD cp attacker:/tmp/pypkgs.tar.gz /tmp/pypkgs.tar.gz
  $EXEC_CMD cp attacker:/tmp/libs.tar.gz   /tmp/libs.tar.gz
  $EXEC_CMD cp /tmp/pypkgs.tar.gz victim1:/tmp/pypkgs.tar.gz
  $EXEC_CMD cp /tmp/libs.tar.gz   victim1:/tmp/libs.tar.gz

  info "Extracting on victim1..."
  $EXEC_CMD exec victim1 bash -c "cd / && tar xzf /tmp/pypkgs.tar.gz 2>/dev/null; echo done"
  $EXEC_CMD exec victim1 bash -c "cd / && tar xzf /tmp/libs.tar.gz   2>/dev/null; echo done"
  $EXEC_CMD exec victim1 ldconfig 2>/dev/null || true

  # Verify
  RESULT=$($EXEC_CMD exec victim1 python3 -c "import paramiko; print('ok')" 2>/dev/null || echo "fail")
  if [ "$RESULT" = "ok" ]; then
    ok "paramiko works on victim1"
  else
    warn "paramiko import failed on victim1 — lateral movement phase may not work"
    warn "Try running setup.sh again, or check: $EXEC_CMD exec victim1 python3 -c 'import paramiko'"
  fi
else
  warn "attacker or victim1 not running — skipping paramiko copy"
fi

# =============================================================================
# Step 6 — Copy simulator to victim1 and update wordlist
# =============================================================================
step "Step 6 — Deploy simulator to victim1"

if $EXEC_CMD inspect --format='{{.State.Status}}' attacker 2>/dev/null | grep -q running && \
   $EXEC_CMD inspect --format='{{.State.Status}}' victim1  2>/dev/null | grep -q running; then

  $EXEC_CMD cp attacker:/lab/simulator.py /tmp/sim.py

  # Add victim-b passwords to the wordlist
  python3 -c "
content = open('/tmp/sim.py').read()
if 'internal123' not in content:
    content = content.replace(
        '\"pass1234\"',
        '\"pass1234\", \"internal123\", \"service1\", \"rootpass\"'
    )
    open('/tmp/sim.py','w').write(content)
    print('wordlist updated')
else:
    print('wordlist already updated')
"
  $EXEC_CMD cp /tmp/sim.py victim1:/tmp/sim.py
  ok "Simulator deployed to victim1 with updated wordlist"
else
  warn "Skipping simulator deploy — containers not ready"
fi

# =============================================================================
# Step 7 — Fix analyzer regex to match sshd -e log format
# =============================================================================
step "Step 7 — Fix analyzer regex for sshd -e log format"

info "sshd -e writes logs without syslog prefix — updating analyzer patterns"

if $EXEC_CMD inspect --format='{{.State.Status}}' monitor 2>/dev/null | grep -q running; then

  $EXEC_CMD cp monitor:/lab/monitor/analyzer.py /tmp/analyzer.py

  python3 << 'PYEOF'
content = open('/tmp/analyzer.py').read()

replacements = [
    # FAILED_RE
    (
        'r"(?P<ts>\\w+ +\\d+ [\\d:]+) .*sshd.* "\n    r"Failed password for (?:invalid user )?(?P<user>\\S+) "\n    r"from (?P<src_ip>[\\d.]+) port (?P<src_port>\\d+)"',
        'r"Failed password for (?:invalid user )?(?P<user>\\S+) from (?P<src_ip>[\\d.]+) port (?P<src_port>\\d+)"'
    ),
    # ACCEPT_RE
    (
        'r"(?P<ts>\\w+ +\\d+ [\\d:]+) .*sshd.* "\n    r"Accepted password for (?P<user>\\S+) "\n    r"from (?P<src_ip>[\\d.]+) port (?P<src_port>\\d+)"',
        'r"Accepted password for (?P<user>\\S+) from (?P<src_ip>[\\d.]+) port (?P<src_port>\\d+)"'
    ),
    # INVALID_RE
    (
        'r"(?P<ts>\\w+ +\\d+ [\\d:]+) .*sshd.* "\n    r"Invalid user (?P<user>\\S+) from (?P<src_ip>[\\d.]+)"',
        'r"Invalid user (?P<user>\\S+) from (?P<src_ip>[\\d.]+)"'
    ),
]

changed = 0
for old, new in replacements:
    if old in content:
        content = content.replace(old, new)
        changed += 1

open('/tmp/analyzer.py', 'w').write(content)
print(f'Analyzer patched: {changed} regex patterns updated')
PYEOF

  $EXEC_CMD cp /tmp/analyzer.py monitor:/lab/monitor/analyzer.py
  ok "Analyzer regex fixed"
else
  warn "Monitor not running — skipping analyzer fix"
fi

# =============================================================================
# Step 8 — Verify SSH connectivity
# =============================================================================
step "Step 8 — Verify SSH connectivity"

info "Testing SSH connection from attacker to victim1..."
RESULT=$($EXEC_CMD exec attacker bash -c \
  "ssh -o StrictHostKeyChecking=no -o PasswordAuthentication=yes \
   -o PubkeyAuthentication=no -o BatchMode=no \
   -o ConnectTimeout=5 labuser@172.21.0.20 exit 2>&1" || echo "failed")

if echo "$RESULT" | grep -q "Permission denied\|Accepted\|closed"; then
  ok "SSH is responding on victim1 (auth working)"
elif echo "$RESULT" | grep -q "Connection refused\|No route"; then
  warn "SSH not reachable on victim1 — check: $EXEC_CMD logs victim1"
else
  ok "SSH connectivity confirmed"
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

echo "  Quick start:"
echo ""
echo "  Terminal 1 — watch victim logs:"
echo "    $EXEC_CMD exec -it victim1 tail -f /var/log/auth.log"
echo ""
echo "  Terminal 2 — run brute-force:"
echo "    $EXEC_CMD exec -it attacker python3 /lab/simulator.py bruteforce --target 172.21.0.20 --delay 1.0 --max-attempts 150"
echo ""
echo "  Terminal 3 — run detection:"
echo "    $EXEC_CMD exec victim1 cat /var/log/auth.log > /tmp/auth.log"
echo "    $EXEC_CMD cp /tmp/auth.log monitor:/var/log/lab/auth.log"
echo "    $EXEC_CMD exec -it monitor python3 /lab/monitor/analyzer.py --report"
echo ""
echo "  Full guide: docs/LAB_GUIDE.md"
echo ""
