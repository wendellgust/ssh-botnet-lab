#!/bin/bash
# =============================================================================
# Attacker container entrypoint
# Prints safety warnings and keeps the container alive for interactive use
# =============================================================================

cat <<'EOF'
╔══════════════════════════════════════════════════════════════════════════════╗
║          SSH BRUTE-FORCE & BOTNET SIMULATION LAB — ATTACKER NODE           ║
╠══════════════════════════════════════════════════════════════════════════════╣
║  EDUCATIONAL USE ONLY                                                       ║
║  This container runs ONLY inside isolated Docker bridge networks.           ║
║  It has NO access to the internet or your host system.                      ║
║  All "attacks" are Python simulations for detection engineering.            ║
╠══════════════════════════════════════════════════════════════════════════════╣
║  Available commands:                                                        ║
║    python3 /lab/simulator.py --help      show all simulation modes          ║
║    python3 /lab/simulator.py bruteforce  simulate SSH brute-force           ║
║    python3 /lab/simulator.py scan        simulate port scanning             ║
║    python3 /lab/simulator.py c2          simulate C2 heartbeat              ║
║    python3 /lab/simulator.py lateral     simulate lateral movement          ║
║    python3 /lab/simulator.py botnet      run full botnet scenario           ║
╚══════════════════════════════════════════════════════════════════════════════╝
EOF

exec /bin/bash
