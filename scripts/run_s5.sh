#!/usr/bin/env bash
# =============================================================================
# run_s5.sh — Scenario 5: Four-Tier Enterprise Chain (3 pivots)
#
# Topology:
#   attack_net  172.21.0.0/24 → victim1 (pivot1)
#   corp_net    10.10.0.0/24  → victim2 (pivot2) + honeypot
#   secure_net  10.50.0.0/24  → victim3 (pivot3)
#   vault_net   10.60.0.0/24  → victim4 + victim5
#
# Chain: attacker → victim1 → victim2 → victim3 → victim4/victim5
#
# Usage:
#   bash scripts/run_s5.sh              # build + run botnet
#   bash scripts/run_s5.sh --setup-only # containers up only
# =============================================================================

SETUP_ONLY=false
[[ "${1:-}" == "--setup-only" ]] && SETUP_ONLY=true

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
log()    { echo -e "${CYAN}[$(date +%H:%M:%S)]${RESET} $*"; }
ok()     { echo -e "${GREEN}[✔]${RESET} $*"; }
warn()   { echo -e "${YELLOW}[!]${RESET} $*"; }
fail()   { echo -e "${RED}[✘]${RESET} $*"; exit 1; }
banner() {
    echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════════════${RESET}"
    echo -e "${BOLD}${CYAN}  $*${RESET}"
    echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════${RESET}\n"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"
YML="scenarios/scenario5.yml"

if command -v podman &>/dev/null; then RT=podman
elif command -v docker &>/dev/null; then RT=docker
else fail "Neither podman nor docker found."; fi
log "Runtime: $RT"

compose_cmd() { $RT compose --project-directory "$SCRIPT_DIR" -f "$YML" "$@"; }

wait_for() {
    local name=$1 i=0
    log "Waiting for $name..."
    while ! $RT exec "$name" echo ok &>/dev/null; do
        sleep 3; ((i++))
        [[ $i -ge 40 ]] && { warn "$name timeout — continuing"; return 0; }
    done
    ok "$name ready"
}

# =============================================================================
banner "PHASE 0 — Setup Scenario 5"

log "Tearing down any existing lab containers..."
for yml in scenarios/scenario{1,2,3,4,5}.yml; do
    [[ -f "$yml" ]] && $RT compose --project-directory "$SCRIPT_DIR" -f "$yml" down 2>/dev/null || true
done
for c in attacker victim1 victim2 victim3 victim4 victim5 honeypot monitor; do
    $RT rm -f "$c" 2>/dev/null || true
done
sleep 2

log "Building services sequentially (avoids OOM)..."
for svc in $(compose_cmd config --services 2>/dev/null); do
    log "  Building $svc..."
    compose_cmd build "$svc" || fail "Build failed: $svc"
    ok "  $svc built"
done

log "Starting containers..."
compose_cmd up -d || fail "Compose up failed"

log "Waiting 12s for containers to initialise..."
sleep 12

for c in attacker victim1 victim2 victim3 victim4 victim5 honeypot monitor; do
    wait_for "$c"
done

log "Giving sshd 8 more seconds to fully settle..."
sleep 8
ok "Scenario 5 is up"

if [[ "$SETUP_ONLY" == "true" ]]; then
    banner "Containers ready — GUI / manual mode"
    echo "  To run botnet manually:"
    echo "    $RT exec -it attacker python3 /lab/botnet.py"
    echo ""
    echo "  To use GUI:"
    echo "    python3 src/gui.py  →  http://localhost:5000"
    exit 0
fi

# =============================================================================
banner "PHASE 1 — Run Autonomous Botnet (botnet.py)"
log "botnet.py will autonomously discover all 4 networks and pivot through them."
log "Expected chain: attacker → victim1 → victim2 → victim3 → victim4/victim5"
echo ""

$RT exec attacker python3 /lab/botnet.py --delay 0.8

ok "Botnet run complete"

# =============================================================================
banner "PHASE 2 — Log Collection & Detection"
> /tmp/a.log
for v in victim1 victim2 victim3 victim4 victim5 honeypot; do
    $RT exec "$v" cat /var/log/auth.log >> /tmp/a.log 2>/dev/null || true
done
$RT exec honeypot cat /var/log/lab/honeypot_events.jsonl > /tmp/honeypot.jsonl 2>/dev/null || true
$RT cp /tmp/honeypot.jsonl monitor:/var/log/lab/honeypot_events.jsonl 2>/dev/null || true
$RT cp /tmp/a.log monitor:/var/log/lab/auth.log

log "$(wc -l < /tmp/a.log) log lines collected"
$RT exec monitor python3 /lab/monitor/analyzer.py --report
ok "Detection complete"

# =============================================================================
banner "DONE — Scenario 5"
echo -e "${CYAN}Useful follow-up:${RESET}"
echo "  $RT exec attacker python3 /lab/botnet.py --report"
echo "  $RT exec -it monitor python3 /lab/monitor/analyzer.py --rules"
echo "  $RT exec -it attacker bash"
echo "  $RT exec -it victim3 bash"
echo "  $RT exec honeypot cat /var/log/lab/honeypot_events.jsonl"
echo ""
echo "Finished: $(date)"
