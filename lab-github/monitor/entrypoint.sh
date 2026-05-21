#!/bin/bash
cat <<'EOF'
╔══════════════════════════════════════════════════════════════════════════╗
║              SSH BOTNET LAB — MONITOR / ANALYST NODE                   ║
╠══════════════════════════════════════════════════════════════════════════╣
║  python3 /lab/monitor/analyzer.py            full analysis             ║
║  python3 /lab/monitor/analyzer.py --live     real-time monitoring      ║
║  python3 /lab/monitor/analyzer.py --report   summary report            ║
║  python3 /lab/monitor/analyzer.py --rules    list detection rules      ║
╚══════════════════════════════════════════════════════════════════════════╝
EOF
exec /bin/bash
