#!/bin/bash
# =============================================================================
# Defense Test Script — SSH Botnet Lab
# Runs the botnet against victim1 with different defenses, collects data.
#
# Usage:  bash defense_test.sh [scenario]   (default: 2)
# Needs:  python3 gui.py running on :5000
#         containers up (auto_run.sh 2)
# =============================================================================

SCENARIO="${1:-2}"
GUI="http://localhost:5000"
EXE="podman"; command -v podman &>/dev/null || EXE="docker"
DELAY="0.5"
TIMEOUT=180
TARGET="victim1"

OUT="defense_data_S${SCENARIO}_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT"

TESTS=(
  "0_baseline:"
  "1_fail2ban:fail2ban"
  "2_block_ip:block_ip"
  "3_rate_limit:rate_limit"
  "4_disable_password:disable_password"
  "5_fail2ban+rate_limit:fail2ban,rate_limit"
  "6_all_defenses:fail2ban,block_ip,rate_limit,disable_password"
)

case "$SCENARIO" in
  1) VICTIMS="victim1 victim2 victim3" ;;
  2) VICTIMS="victim1 victim2 victim3 honeypot" ;;
  3) VICTIMS="victim1 victim2 victim3 victim4 victim5 honeypot" ;;
  4) VICTIMS="victim1 victim2 victim3 victim4 victim5 honeypot" ;;
  *) VICTIMS="victim1 victim2 victim3 honeypot" ;;
esac

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

# ── helpers ───────────────────────────────────────────────────────────────────

wait_for_ssh() {
  local host="$1" tries=0
  while [ $tries -lt 20 ]; do
    $EXE exec "$host" bash -c 'ss -tlnp | grep -q ":22"' 2>/dev/null && return 0
    sleep 2; tries=$((tries+1))
  done
  echo "    WARNING: $host sshd may not be ready"
}

# Wait until GUI state shows not-running and not-done (clean slate)
wait_gui_idle() {
  local tries=0
  while [ $tries -lt 20 ]; do
    local st running done_flag
    st=$(curl -sf "$GUI/state" 2>/dev/null)
    running=$(echo "$st" | python3 -c "import sys,json; print(json.load(sys.stdin).get('running',True))"  2>/dev/null)
    done_flag=$(echo "$st" | python3 -c "import sys,json; print(json.load(sys.stdin).get('done',False))" 2>/dev/null)
    [ "$running" = "False" ] && return 0
    sleep 3; tries=$((tries+1))
  done
}

reset_gui() {
  # Stop any running botnet first, then reset
  curl -sf "$GUI/stop"  2>/dev/null; sleep 2
  wait_gui_idle
  curl -sf "$GUI/reset" 2>/dev/null
  sleep 1
}

apply_defense() {
  local action="$1" target="$2"
  local result ok msg
  result=$(curl -sf "$GUI/defend?action=${action}&target=${target}" 2>/dev/null)
  ok=$(echo  "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ok',False))" 2>/dev/null)
  msg=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('msg','?'))"  2>/dev/null)
  if [ "$ok" = "True" ]; then
    echo -e "    ${GREEN}✓${NC} $action → $target: $msg"
  else
    echo -e "    ${RED}✗${NC} $action → $target: $msg"
  fi
}

run_botnet_and_wait() {
  curl -sf "$GUI/run?delay=$DELAY" 2>/dev/null
  local elapsed=0
  while [ $elapsed -lt $TIMEOUT ]; do
    sleep 5; elapsed=$((elapsed+5))
    local st done_flag
    st=$(curl -sf "$GUI/state" 2>/dev/null)
    done_flag=$(echo "$st" | python3 -c "import sys,json; print(json.load(sys.stdin).get('done',False))" 2>/dev/null)
    [ "$done_flag" = "True" ] && echo "    Finished in ${elapsed}s" && return 0
    [ $((elapsed % 30)) -eq 0 ] && echo "    ...running ${elapsed}s..."
  done
  echo -e "    ${YELLOW}TIMEOUT after ${TIMEOUT}s — collecting anyway${NC}"
  curl -sf "$GUI/stop" 2>/dev/null
  sleep 3
}

collect_data() {
  local dir="$1"
  curl -sf "$GUI/report" 2>/dev/null | python3 -m json.tool > "$dir/gui_report.json" 2>/dev/null
  for v in $VICTIMS; do
    $EXE exec "$v" cat /var/log/auth.log 2>/dev/null > "$dir/${v}_auth.log" \
      || rm -f "$dir/${v}_auth.log"
  done
  $EXE exec "$TARGET" fail2ban-client status sshd    2>/dev/null > "$dir/fail2ban_status.txt" || true
  $EXE exec "$TARGET" iptables -L INPUT -n -v        2>/dev/null > "$dir/iptables.txt"        || true
  $EXE exec "$TARGET" grep "PasswordAuthentication" /etc/ssh/sshd_config 2>/dev/null \
    > "$dir/sshd_config.txt" || true
}

write_summary() {
  local dir="$1" name="$2" defenses="$3"
  {
    echo "Test:     $name"
    echo "Defenses: ${defenses:-none}"
    echo "Target:   $TARGET"
    echo ""
    printf "%-12s  %-8s  %-8s\n" "Host" "Failed" "Accepted"
    echo "──────────────────────────"
    for v in $VICTIMS; do
      local f="$dir/${v}_auth.log"
      [ -f "$f" ] || continue
      printf "%-12s  %-8s  %-8s\n" "$v" \
        "$(grep 'Failed password'   "$f" 2>/dev/null | wc -l)" \
        "$(grep 'Accepted password' "$f" 2>/dev/null | wc -l)"
    done
    echo ""
    python3 -c "
import json, sys
try:
    d = json.load(open('$dir/gui_report.json'))
except:
    print('(no GUI report)'); sys.exit(0)
s = d.get('stats', {})
print(f'Found: {s.get(\"found\",0)}  Compromised: {s.get(\"compromised\",0)}  Networks: {s.get(\"nets\",0)}')
print()
for h in d.get('hosts', []):
    icon = '✓' if h['state']=='compromised' else '✗'
    cred = f'{h[\"user\"]}:{h[\"pwd\"]}' if h.get('user') else '—'
    via  = h.get('via') or 'direct'
    print(f'  {icon} {h[\"ip\"]:15s}  {h[\"state\"]:12s}  {cred:20s}  via {via}')
alerts = d.get('alerts', [])
if alerts:
    print()
    for a in alerts: print(f'  ⚠ {a}')
" 2>/dev/null
  } | tee "$dir/summary.txt"
}

run_test() {
  local name="$1" defenses="$2"
  local dir="$OUT/$name"
  mkdir -p "$dir"

  echo ""
  echo -e "${CYAN}══════════════════════════════════════════════${NC}"
  echo -e "${CYAN} TEST: $name  |  Defenses: ${defenses:-none}${NC}"
  echo -e "${CYAN}══════════════════════════════════════════════${NC}"

  # 1. Stop running botnet, reset GUI state
  echo "  Stopping any running botnet..."
  reset_gui
  echo "  GUI reset ✓"

  # 2. Restart victims — wipes iptables, fail2ban bans, and auth logs
  echo "  Restarting victims..."
  for v in $VICTIMS; do
    $EXE restart "$v" 2>/dev/null && echo "    $v ✓" || echo "    $v not found"
  done

  # 3. Clear auth logs (restart keeps filesystem; truncate explicitly)
  echo "  Clearing auth logs..."
  for v in $VICTIMS; do
    $EXE exec "$v" bash -c 'truncate -s 0 /var/log/auth.log 2>/dev/null; true'
  done

  # 4. Wait for sshd on all victims
  echo "  Waiting for sshd..."
  for v in $VICTIMS; do wait_for_ssh "$v"; done
  sleep 2

  # 5. Apply defenses
  if [ -n "$defenses" ]; then
    echo "  Applying defenses to $TARGET..."
    IFS=',' read -ra dlist <<< "$defenses"
    for def in "${dlist[@]}"; do
      apply_defense "$def" "$TARGET"
      sleep 2
    done
    sleep 2  # extra settle time
  fi

  # 6. Run botnet
  echo "  Running botnet..."
  run_botnet_and_wait

  # 7. Collect
  echo "  Collecting data..."
  collect_data "$dir"

  echo ""
  write_summary "$dir" "$name" "$defenses"
}

# ── Main ──────────────────────────────────────────────────────────────────────

echo -e "${CYAN}"
echo "  SSH Botnet Lab — Defense Test Runner"
echo "  Scenario: $SCENARIO  |  Target: $TARGET  |  Output: $OUT/"
echo -e "${NC}"

if ! curl -sf "$GUI/" >/dev/null 2>&1; then
  echo -e "${RED}ERROR: GUI not reachable at $GUI — run: python3 gui.py${NC}"
  exit 1
fi

for test_def in "${TESTS[@]}"; do
  run_test "${test_def%%:*}" "${test_def#*:}"
done

# ── Comparison table ──────────────────────────────────────────────────────────
{
  echo ""
  printf "%-30s  %-10s  %-10s  %-10s  %-8s\n" "Test" "v1 Failed" "v1 Accept" "Compromised" "Pivoted"
  echo "────────────────────────────────────────────────────────────────────"
  for test_def in "${TESTS[@]}"; do
    tname="${test_def%%:*}"
    dir="$OUT/$tname"
    [ -d "$dir" ] || continue
    v1f=$(grep "Failed password"   "$dir/victim1_auth.log" 2>/dev/null | wc -l)
    v1a=$(grep "Accepted password" "$dir/victim1_auth.log" 2>/dev/null | wc -l)
    comp=$(python3 -c "
import json
d=json.load(open('$dir/gui_report.json'))
print(d['stats']['compromised'])
" 2>/dev/null || echo "?")
    pivoted=$(python3 -c "
import json
d=json.load(open('$dir/gui_report.json'))
print('YES' if any(h['ip'].startswith('10.') and h['state']=='compromised' for h in d.get('hosts',[])) else 'NO')
" 2>/dev/null || echo "?")
    printf "%-30s  %-10s  %-10s  %-10s  %-8s\n" "$tname" "$v1f" "$v1a" "$comp" "$pivoted"
  done
} | tee "$OUT/comparison.txt"

echo ""
echo -e "${GREEN}Done. Data in $OUT/${NC}"
