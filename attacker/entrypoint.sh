#!/bin/bash
cat <<'EOF'
╔══════════════════════════════════════════════════════════════╗
║  BOTNET SIMULATOR — EDUCATIONAL USE ONLY                    ║
║  All traffic inside isolated Docker networks                ║
╠══════════════════════════════════════════════════════════════╣
║  python3 /lab/simulator.py bruteforce --target 172.21.0.20  ║
║  python3 /lab/simulator.py scan       --network 172.21.0.   ║
║  python3 /lab/simulator.py c2         --c2-host 172.21.0.10 ║
║  python3 /lab/simulator.py botnet                           ║
╚══════════════════════════════════════════════════════════════╝
EOF
exec /bin/bash
