#!/bin/bash
# =============================================================================
# SSH Brute-Force & Botnet Lab — One-shot Setup Script
# FEUP SSR 2026 — Educational use only
# Usage: chmod +x setup.sh && ./setup.sh
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

# ── Step 1: detect runtime ────────────────────────────────────────────────────
step "Step 1 — Detect container runtime"

EXE=""; COMPOSE=""
if command -v podman &>/dev/null; then
  ok "Found podman $(podman --version | awk '{print $3}')"
  EXE="podman"
  systemctl --user start  podman.socket 2>/dev/null || true
  systemctl --user enable podman.socket 2>/dev/null || true
  if command -v docker-compose &>/dev/null; then COMPOSE="docker-compose"
  elif docker compose version &>/dev/null 2>&1;  then COMPOSE="docker compose"
  else fail "No compose found. Run: sudo apt install docker-compose-plugin"; fi
elif command -v docker &>/dev/null; then
  ok "Found docker"; EXE="docker"; COMPOSE="docker compose"
else
  fail "Install podman: sudo apt install podman podman-compose"
fi
ok "Using compose: $COMPOSE"

# ── Step 2: clean up old containers/networks ──────────────────────────────────
step "Step 2 — Clean up old containers and networks"

for c in attacker victim1 victim2 victim3 honeypot monitor; do
  $EXE rm -f $c 2>/dev/null && info "Removed container: $c" || true
done
for n in \
  ssh-botnet-lab_attack_net ssh-botnet-lab_internal_net \
  lab-github_attack_net     lab-github_internal_net \
  lab-v3_attack_net         lab-v3_internal_net \
  lab-final_attack_net      lab-final_internal_net \
  dokcer_botnet-lab; do
  $EXE network rm $n 2>/dev/null && info "Removed network: $n" || true
done
ok "Cleanup done"

# ── Step 3: build and start ───────────────────────────────────────────────────
step "Step 3 — Build images and start containers"
info "First run takes 3-5 minutes (downloads Ubuntu base image)"

$COMPOSE up -d --build

info "Waiting 8 seconds for containers to initialise..."
sleep 8

ALL_UP=true
for c in attacker victim1 victim2 victim3 honeypot monitor; do
  S=$($EXE inspect --format='{{.State.Status}}' $c 2>/dev/null || echo "missing")
  if [ "$S" = "running" ]; then ok "$c is running"
  else warn "$c status: $S"; ALL_UP=false; fi
done
[ "$ALL_UP" = false ] && warn "Some containers not running — check: $EXE logs victim1"

# ── Step 4: verify SSH on victims ─────────────────────────────────────────────
step "Step 4 — Verify SSH on all victims"

for c in victim1 victim2 victim3 honeypot; do
  if ! $EXE inspect --format='{{.State.Status}}' $c 2>/dev/null | grep -q running; then
    warn "$c not running, skipping"; continue
  fi
  # Check if sshd is listening
  LISTENING=$($EXE exec $c ss -tlnp 2>/dev/null | grep ':22' || echo "")
  if [ -n "$LISTENING" ]; then
    ok "SSH listening on $c"
  else
    warn "$c sshd not listening — restarting..."
    $EXE exec $c bash -c "
      mkdir -p /run/sshd
      ssh-keygen -A 2>/dev/null
      pkill -x sshd 2>/dev/null || true
      sleep 1
      /usr/sbin/sshd -D -e 2>> /var/log/auth.log &
      sleep 2
    " 2>/dev/null && ok "sshd restarted on $c" || warn "Could not restart on $c"
  fi
done

# ── Step 5: copy paramiko to victim1 ─────────────────────────────────────────
step "Step 5 — Copy Python libraries to victim1 (needed for lateral movement)"

if $EXE inspect --format='{{.State.Status}}' attacker 2>/dev/null | grep -q running && \
   $EXE inspect --format='{{.State.Status}}' victim1  2>/dev/null | grep -q running; then

  ALREADY=$($EXE exec victim1 python3 -c "import paramiko; print('ok')" 2>/dev/null || echo "no")
  if [ "$ALREADY" = "ok" ]; then
    ok "paramiko already on victim1"
  else
    info "Copying packages from attacker..."
    $EXE exec attacker bash -c \
      "tar czf /tmp/pkgs.tar.gz /usr/lib/python3/dist-packages/ 2>/dev/null"
    $EXE exec attacker bash -c \
      "tar czf /tmp/libs.tar.gz \
        /usr/lib/x86_64-linux-gnu/libsodium* \
        /usr/lib/x86_64-linux-gnu/libcrypto* \
        /usr/lib/x86_64-linux-gnu/libssl* 2>/dev/null"
    $EXE cp attacker:/tmp/pkgs.tar.gz /tmp/pkgs_lab.tar.gz
    $EXE cp attacker:/tmp/libs.tar.gz  /tmp/libs_lab.tar.gz
    $EXE cp /tmp/pkgs_lab.tar.gz victim1:/tmp/pkgs.tar.gz
    $EXE cp /tmp/libs_lab.tar.gz  victim1:/tmp/libs.tar.gz
    $EXE exec victim1 bash -c "cd / && tar xzf /tmp/pkgs.tar.gz 2>/dev/null"
    $EXE exec victim1 bash -c "cd / && tar xzf /tmp/libs.tar.gz  2>/dev/null"
    $EXE exec victim1 ldconfig 2>/dev/null || true
    R=$($EXE exec victim1 python3 -c "import paramiko; print('ok')" 2>/dev/null || echo "fail")
    if [ "$R" = "ok" ]; then ok "paramiko works on victim1"
    else warn "paramiko failed — lateral movement phase may not work"; fi
  fi
else
  warn "Skipping paramiko copy — containers not ready"
fi

# ── Step 6: deploy simulator to victim1 ──────────────────────────────────────
step "Step 6 — Deploy simulator to victim1"

if $EXE inspect --format='{{.State.Status}}' attacker 2>/dev/null | grep -q running && \
   $EXE inspect --format='{{.State.Status}}' victim1  2>/dev/null | grep -q running; then
  $EXE cp attacker:/lab/simulator.py /tmp/sim_setup.py
  python3 -c "
c = open('/tmp/sim_setup.py').read()
if 'internal123' not in c:
    c = c.replace('\"pass1234\"', '\"pass1234\", \"internal123\", \"service1\", \"rootpass\"')
    open('/tmp/sim_setup.py','w').write(c)
    print('wordlist updated')
else:
    print('wordlist already updated')
"
  $EXE cp /tmp/sim_setup.py victim1:/tmp/sim.py
  ok "Simulator on victim1 at /tmp/sim.py"
else
  warn "Skipping simulator deploy"
fi

# ── Step 7: final SSH test ────────────────────────────────────────────────────
step "Step 7 — Final SSH test"

sleep 1
R=$($EXE exec attacker bash -c \
  "ssh -o StrictHostKeyChecking=no \
       -o PasswordAuthentication=yes \
       -o PubkeyAuthentication=no \
       -o BatchMode=no \
       -o ConnectTimeout=5 \
       labuser@172.21.0.20 'echo OK' 2>&1" || echo "FAIL")

if echo "$R" | grep -qE "^OK$|Permission denied"; then
  ok "SSH to victim1 is working"
else
  warn "SSH test result: $R"
  warn "Try manually: $EXE exec -it attacker ssh labuser@172.21.0.20  (pass: password123)"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}"
cat <<'DONE'
  ╔═══════════════════════════════════════════════════╗
  ║              LAB READY                           ║
  ╚═══════════════════════════════════════════════════╝
DONE
echo -e "${NC}"
echo "  Terminal 1 — watch logs:"
echo "    $EXE exec -it victim1 tail -f /var/log/auth.log"
echo ""
echo "  Terminal 2 — run attack:"
echo "    $EXE exec -it attacker python3 /lab/simulator.py bruteforce --target 172.21.0.20 --delay 1.0 --max-attempts 150"
echo ""
echo "  Terminal 3 — run detection:"
echo "    $EXE exec victim1 cat /var/log/auth.log > /tmp/a.log && $EXE cp /tmp/a.log monitor:/var/log/lab/auth.log"
echo "    $EXE exec -it monitor python3 /lab/monitor/analyzer.py --report"
echo ""
echo "  Full guide: docs/LAB_GUIDE.md"
echo ""
