#!/bin/bash
# =============================================================================
# SSH Botnet Lab — Setup Script  (fixed runtime detection)
# FEUP SSR 2026 — Educational use only
# Usage: chmod +x setup.sh && ./setup.sh
# =============================================================================

# NO set -e — handle errors manually so detection never dies silently

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

EXE=""
COMPOSE=""

# Try podman first — check multiple common paths
for path in podman /usr/bin/podman /usr/local/bin/podman; do
  if "$path" --version >/dev/null 2>&1; then
    EXE="$path"
    ok "Found: $EXE $($EXE --version 2>/dev/null | awk '{print $3}')"
    break
  fi
done

# Fall back to docker
if [ -z "$EXE" ]; then
  for path in docker /usr/bin/docker /usr/local/bin/docker; do
    if "$path" --version >/dev/null 2>&1; then
      EXE="$path"
      ok "Found: $EXE"
      break
    fi
  done
fi

[ -z "$EXE" ] && fail "Neither podman nor docker found. Run: sudo apt install podman"

# Enable podman socket if using podman (best-effort, not fatal)
if echo "$EXE" | grep -q podman; then
  systemctl --user start  podman.socket 2>/dev/null || true
  systemctl --user enable podman.socket 2>/dev/null || true
fi

# Detect compose — try all common providers
for try in "docker-compose" "podman-compose" "docker compose"; do
  if $try version >/dev/null 2>&1; then
    COMPOSE="$try"
    ok "Compose: $COMPOSE"
    break
  fi
done

if [ -z "$COMPOSE" ]; then
  # Last resort: check if docker-compose binary exists
  if [ -f /usr/libexec/docker/cli-plugins/docker-compose ]; then
    COMPOSE="docker-compose"
    ok "Compose (plugin): $COMPOSE"
  else
    fail "No compose found. Run: sudo apt install docker-compose-plugin"
  fi
fi

# ── Step 2: clean up ─────────────────────────────────────────────────────────
step "Step 2 — Clean up old containers and networks"

for c in attacker victim1 victim2 victim3 victim4 victim5 honeypot monitor; do
  $EXE rm -f $c 2>/dev/null && info "Removed: $c" || true
done

for n in \
  ssh-botnet-lab_attack_net  ssh-botnet-lab_internal_net \
  lab-github_attack_net      lab-github_internal_net \
  lab-v3_attack_net          lab-v3_internal_net \
  lab-final_attack_net       lab-final_internal_net \
  lab-final2_attack_net      lab-final2_internal_net \
  lab-botnet_attack_net      lab-botnet_internal_net \
  lab-botnet_extra_net       lab-botnet_deep_net \
  dokcer_botnet-lab; do
  $EXE network rm $n 2>/dev/null && info "Removed network: $n" || true
done
ok "Cleanup done"

# ── Step 3: build and start ───────────────────────────────────────────────────
step "Step 3 — Build and start (Scenario 2 — standard lab)"
info "First run takes 3-5 min (downloads Ubuntu base image)"

$COMPOSE -f scenarios/scenario2.yml up -d --build
BUILD_EXIT=$?
if [ $BUILD_EXIT -ne 0 ]; then
  warn "Compose exited with code $BUILD_EXIT — check output above"
fi

info "Waiting 8 seconds for containers to initialise..."
sleep 8

ALL_UP=true
for c in attacker victim1 victim2 victim3 honeypot monitor; do
  S=$($EXE inspect --format='{{.State.Status}}' $c 2>/dev/null || echo "missing")
  if [ "$S" = "running" ]; then ok "$c is running"
  else warn "$c status: $S"; ALL_UP=false; fi
done
[ "$ALL_UP" = false ] && warn "Some containers not running — check: $EXE logs victim1"

# ── Step 4: verify SSH ────────────────────────────────────────────────────────
step "Step 4 — Verify SSH on victims"

for c in victim1 victim2 victim3 honeypot; do
  if ! $EXE inspect --format='{{.State.Status}}' $c 2>/dev/null | grep -q running; then
    continue
  fi
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
    " 2>/dev/null && ok "sshd restarted on $c" || warn "Could not restart $c"
  fi
done

# ── Step 5: copy paramiko to victim1 ─────────────────────────────────────────
step "Step 5 — Copy Python libraries to victim1"

if $EXE inspect --format='{{.State.Status}}' attacker 2>/dev/null | grep -q running && \
   $EXE inspect --format='{{.State.Status}}' victim1  2>/dev/null | grep -q running; then

  ALREADY=$($EXE exec victim1 python3 -c "import paramiko; print('ok')" 2>/dev/null || echo "no")
  if [ "$ALREADY" = "ok" ]; then
    ok "paramiko already on victim1"
  else
    info "Copying packages from attacker..."
    $EXE exec attacker bash -c \
      "tar czf /tmp/pkgs.tar.gz /usr/lib/python3/dist-packages/ 2>/dev/null" || true
    $EXE exec attacker bash -c \
      "tar czf /tmp/libs.tar.gz \
        /usr/lib/x86_64-linux-gnu/libsodium* \
        /usr/lib/x86_64-linux-gnu/libcrypto* \
        /usr/lib/x86_64-linux-gnu/libssl* 2>/dev/null" || true
    $EXE cp attacker:/tmp/pkgs.tar.gz /tmp/pkgs_l.tar.gz 2>/dev/null || true
    $EXE cp attacker:/tmp/libs.tar.gz  /tmp/libs_l.tar.gz 2>/dev/null || true
    $EXE cp /tmp/pkgs_l.tar.gz victim1:/tmp/pkgs.tar.gz 2>/dev/null || true
    $EXE cp /tmp/libs_l.tar.gz  victim1:/tmp/libs.tar.gz 2>/dev/null || true
    $EXE exec victim1 bash -c "cd / && tar xzf /tmp/pkgs.tar.gz 2>/dev/null" || true
    $EXE exec victim1 bash -c "cd / && tar xzf /tmp/libs.tar.gz  2>/dev/null" || true
    $EXE exec victim1 ldconfig 2>/dev/null || true
    R=$($EXE exec victim1 python3 -c "import paramiko; print('ok')" 2>/dev/null || echo "fail")
    [ "$R" = "ok" ] && ok "paramiko works on victim1" || warn "paramiko failed"
  fi
else
  warn "Skipping paramiko — containers not ready"
fi

# ── Step 6: deploy simulator + botnet.py to victim1 ──────────────────────────
step "Step 6 — Deploy simulator and botnet.py to victim1"

if $EXE inspect --format='{{.State.Status}}' attacker 2>/dev/null | grep -q running && \
   $EXE inspect --format='{{.State.Status}}' victim1  2>/dev/null | grep -q running; then

  $EXE cp attacker:/lab/simulator.py /tmp/sim_s.py 2>/dev/null || true
  if [ -f /tmp/sim_s.py ]; then
    python3 -c "
c=open('/tmp/sim_s.py').read()
if 'internal123' not in c:
    c=c.replace('\"pass1234\"','\"pass1234\",\"internal123\",\"service1\",\"rootpass\",\"deepnet123\"')
    open('/tmp/sim_s.py','w').write(c)
    print('wordlist updated')
else:
    print('wordlist already updated')
" 2>/dev/null || true
    $EXE cp /tmp/sim_s.py victim1:/tmp/sim.py 2>/dev/null || true
    ok "simulator deployed to victim1 at /tmp/sim.py"
  fi

  $EXE cp attacker:/lab/botnet.py victim1:/tmp/botnet.py 2>/dev/null && \
    ok "botnet.py deployed to victim1 at /tmp/botnet.py" || \
    warn "botnet.py not found on attacker"
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
       labuser@172.21.0.20 'echo OK' 2>&1" 2>/dev/null || echo "FAIL")

if echo "$R" | grep -qE "^OK$|Permission denied"; then
  ok "SSH to victim1 confirmed — lab is working"
elif echo "$R" | grep -q "timed out\|Connection refused"; then
  warn "SSH not responding — check: $EXE logs victim1"
else
  ok "SSH is responding"
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
echo "  Run autonomous botnet (auto-discovers topology):"
echo "    $EXE exec -it attacker python3 /lab/botnet.py"
echo ""
echo "  Or brute-force manually:"
echo "    $EXE exec -it attacker python3 /lab/simulator.py bruteforce --target 172.21.0.20 --delay 1.0 --max-attempts 150"
echo ""
echo "  Switch scenario:"
echo "    ./start.sh 1   ./start.sh 2   ./start.sh 3   ./start.sh 4"
echo ""
echo "  Guide: docs/LAB_GUIDE.md"
echo ""
