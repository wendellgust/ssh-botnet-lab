#!/bin/bash
# =============================================================================
# Lab Scenario Launcher
# Usage: ./start.sh [1|2|3|4]
# =============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

SCENARIO="${1:-}"

if [ -z "$SCENARIO" ]; then
  echo -e "${CYAN}"
  cat <<'MENU'
  ╔═══════════════════════════════════════════════════════════════╗
  ║         SSH Botnet Lab — Scenario Selector                   ║
  ╠═══════════════════════════════════════════════════════════════╣
  ║  1  Single network — no segmentation, direct access          ║
  ║     attacker → victim1, victim2, victim3 (all visible)       ║
  ║                                                               ║
  ║  2  Two networks — current lab setup                          ║
  ║     attacker → victim1 (pivot) → victim3, honeypot           ║
  ║                                                               ║
  ║  3  Three networks — two parallel pivots                      ║
  ║     attacker → victim1 → internal_net                        ║
  ║     attacker → victim2 → extra_net                           ║
  ║                                                               ║
  ║  4  Deep chain — three hops                                   ║
  ║     attacker → victim1 → victim3 (pivot2) → deep_net         ║
  ╚═══════════════════════════════════════════════════════════════╝
MENU
  echo -e "${NC}"
  read -p "  Select scenario [1-4]: " SCENARIO
fi

case "$SCENARIO" in
  1) FILE="scenarios/scenario1.yml"
     DESC="Single Network"
     ATTACK_CMD="python3 /lab/botnet.py --delay 0.5" ;;
  2) FILE="scenarios/scenario2.yml"
     DESC="Two Networks (standard lab)"
     ATTACK_CMD="python3 /lab/botnet.py" ;;
  3) FILE="scenarios/scenario3.yml"
     DESC="Three Networks (two pivots)"
     ATTACK_CMD="python3 /lab/botnet.py" ;;
  4) FILE="scenarios/scenario4.yml"
     DESC="Deep Chain (three hops)"
     ATTACK_CMD="python3 /lab/botnet.py" ;;
  *) echo -e "${RED}Invalid scenario. Choose 1-4.${NC}"; exit 1 ;;
esac

# Detect runtime
EXE="podman"; COMPOSE="docker-compose"
command -v podman &>/dev/null || EXE="docker"
docker compose version &>/dev/null 2>&1 && COMPOSE="docker compose"

echo -e "${CYAN}══ Scenario $SCENARIO — $DESC ══${NC}"

# Stop existing containers
echo "Stopping existing containers..."
for c in attacker victim1 victim2 victim3 victim4 victim5 honeypot monitor; do
  $EXE rm -f $c 2>/dev/null || true
done

# Remove old networks
for n in $($EXE network ls --format '{{.Name}}' 2>/dev/null | grep -E "attack|internal|extra|deep|botnet"); do
  $EXE network rm $n 2>/dev/null || true
done

echo "Building and starting Scenario $SCENARIO..."
$COMPOSE --project-directory . -f "$FILE" up -d --build

echo "Waiting for containers..."
sleep 8

# Run setup steps (paramiko copy etc.)
echo "Running post-start setup..."
bash setup.sh --no-build 2>/dev/null || true

echo -e "${GREEN}"
echo "  Scenario $SCENARIO ready — $DESC"
echo ""
echo "  Run the autonomous botnet:"
echo "    $EXE exec -it attacker $ATTACK_CMD"
echo ""
echo "  Watch logs:"
echo "    $EXE exec -it victim1 tail -f /var/log/auth.log"
echo ""
echo "  Detect:"
echo "    $EXE exec victim1 cat /var/log/auth.log > /tmp/a.log"
echo "    $EXE cp /tmp/a.log monitor:/var/log/lab/auth.log"
echo "    $EXE exec -it monitor python3 /lab/monitor/analyzer.py --report"
echo -e "${NC}"
