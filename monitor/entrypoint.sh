#!/bin/bash
cat <<'EOF'
╔══════════════════════════════════════════════════════════════╗
║           SSH BOTNET LAB — MONITOR NODE                     ║
╠══════════════════════════════════════════════════════════════╣
║  python3 /lab/monitor/analyzer.py             full analysis ║
║  python3 /lab/monitor/analyzer.py --live      real-time     ║
║  python3 /lab/monitor/analyzer.py --report    summary       ║
║  python3 /lab/monitor/analyzer.py --rules     list rules    ║
╚══════════════════════════════════════════════════════════════╝
EOF
exec /bin/bash
