#!/bin/bash
# =============================================================================
# Lab Data Collector — SSH Botnet Lab
# Run after a botnet scenario to dump all evidence into a timestamped folder.
# Usage: bash collect_data.sh [scenario_number]
# =============================================================================

SCENARIO="${1:-?}"
OUT="lab_data_S${SCENARIO}_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT"

EXE="podman"; command -v podman &>/dev/null || EXE="docker"

echo "Collecting data → $OUT/"

# ── 1. GUI report JSON ────────────────────────────────────────────────────────
echo "  [1/6] GUI report..."
curl -s http://localhost:5000/report 2>/dev/null \
  | python3 -m json.tool > "$OUT/gui_report.json" \
  && echo "       gui_report.json" \
  || echo "       SKIP: GUI not running (start python3 gui.py first)"

# ── 2. Auth logs from all victims ─────────────────────────────────────────────
echo "  [2/6] Auth logs..."
for v in victim1 victim2 victim3 victim4 victim5 honeypot; do
  $EXE exec "$v" cat /var/log/auth.log 2>/dev/null > "$OUT/${v}_auth.log" \
    && echo "       ${v}_auth.log ($(wc -l < "$OUT/${v}_auth.log") lines)" \
    || { rm -f "$OUT/${v}_auth.log"; echo "       SKIP: $v not running"; }
done

# ── 3. Network routes (show dual-homed pivot hosts) ───────────────────────────
echo "  [3/6] Network routes..."
for v in victim1 victim2 victim3 victim4 victim5; do
  $EXE exec "$v" ip route 2>/dev/null > "$OUT/${v}_routes.txt" \
    && echo "       ${v}_routes.txt" \
    || { rm -f "$OUT/${v}_routes.txt"; true; }
done

# ── 4. Container IP / network membership ──────────────────────────────────────
echo "  [4/6] Container IPs..."
{
  echo "Container → Network → IP"
  echo "──────────────────────────────────────────"
  for v in attacker victim1 victim2 victim3 victim4 victim5 honeypot monitor; do
    $EXE inspect "$v" 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)[0]
nets = d['NetworkSettings']['Networks']
for n, info in nets.items():
    print(f'  $v  {n}  {info[\"IPAddress\"]}')
" 2>/dev/null || true
  done
} > "$OUT/container_ips.txt"
echo "       container_ips.txt"

# ── 5. Credential list from botnet.py ─────────────────────────────────────────
echo "  [5/6] Credential list..."
$EXE exec attacker python3 -c "
import re, ast
src = open('/lab/botnet.py').read()
u = ast.literal_eval(re.search(r'USERNAMES\s*=\s*(\[.*?\])', src, re.S).group(1))
p = ast.literal_eval(re.search(r'PASSWORDS\s*=\s*(\[.*?\])', src, re.S).group(1))
print(f'Usernames ({len(u)}): {u}')
print(f'Passwords ({len(p)}): {p}')
print(f'Total combinations: {len(u)*len(p)}')
" 2>/dev/null > "$OUT/credential_list.txt" \
  && echo "       credential_list.txt" \
  || echo "       SKIP: attacker not running"

# ── 6. Summary stats from auth logs ───────────────────────────────────────────
echo "  [6/6] Summary stats..."
{
  echo "Auth Log Summary"
  echo "──────────────────────────────────────────"
  printf "%-12s  %-8s  %-8s\n" "Container" "Failed" "Accepted"
  echo "──────────────────────────────────────────"
  for v in victim1 victim2 victim3 victim4 victim5 honeypot; do
    f="$OUT/${v}_auth.log"
    [ -f "$f" ] || continue
    failed=$(grep -c "Failed password" "$f" 2>/dev/null || echo 0)
    accepted=$(grep -c "Accepted password" "$f" 2>/dev/null || echo 0)
    printf "%-12s  %-8s  %-8s\n" "$v" "$failed" "$accepted"
  done
  echo ""
  echo "Top source IPs (by failed attempts across all victims):"
  cat "$OUT"/victim*_auth.log "$OUT"/honeypot_auth.log 2>/dev/null \
    | grep "Failed password" \
    | awk '{for(i=1;i<=NF;i++) if($i=="from"){print $(i+1); break}}' \
    | sort | uniq -c | sort -rn | head -5
  echo ""
  echo "Usernames most tried:"
  cat "$OUT"/victim*_auth.log "$OUT"/honeypot_auth.log 2>/dev/null \
    | grep "Failed password" \
    | awk '{for(i=1;i<=NF;i++) if($i=="for"){u=$(i+1); if(u=="invalid") u=$(i+2); print u; break}}' \
    | sort | uniq -c | sort -rn | head -10
} > "$OUT/summary.txt"
echo "       summary.txt"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "Done. Files saved to $OUT/"
echo ""
ls -lh "$OUT/"
