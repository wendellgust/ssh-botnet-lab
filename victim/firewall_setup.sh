#!/bin/bash
# =============================================================================
# Firewall Setup Script — Lab Victim Containers
# Run this INSIDE a victim container to demonstrate firewall concepts
#
# Usage:
#   docker exec -it victim1 bash /lab/firewall_setup.sh [phase]
#
# Phases:
#   weak      — no firewall (lab default, for attack simulation)
#   moderate  — rate-limiting and logging only
#   hardened  — full hardening (blocks brute-force)
#   demo      — shows all rules with explanations
# =============================================================================

PHASE="${1:-demo}"

echo "============================================================"
echo " Firewall Setup — Phase: $PHASE"
echo "============================================================"

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------
rule_explain() {
    echo ""
    echo "  RULE: $1"
    echo "  WHY:  $2"
}

# ---------------------------------------------------------------------------
# Phase: WEAK — flush all rules (simulates a misconfigured server)
# ---------------------------------------------------------------------------
if [ "$PHASE" = "weak" ]; then
    echo "[WEAK] Flushing all firewall rules — SSH completely exposed"
    iptables -F INPUT
    iptables -F OUTPUT
    iptables -F FORWARD
    iptables -P INPUT ACCEPT
    iptables -P OUTPUT ACCEPT
    iptables -P FORWARD ACCEPT
    echo "[WEAK] No firewall rules. Brute-force will succeed."
    exit 0
fi

# ---------------------------------------------------------------------------
# Phase: MODERATE — rate limiting and logging (detection without blocking)
# ---------------------------------------------------------------------------
if [ "$PHASE" = "moderate" ]; then
    echo "[MODERATE] Applying rate-limit and logging rules"
    iptables -F INPUT

    # Allow established connections (stateful)
    rule_explain \
        "iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT" \
        "Allow traffic that is part of an already-established session"
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

    # Allow loopback
    iptables -A INPUT -i lo -j ACCEPT

    # Log SSH connection attempts (for detection)
    rule_explain \
        "iptables -A INPUT -p tcp --dport 22 -m state --state NEW -j LOG" \
        "Log every new SSH connection attempt — feeds detection rules"
    iptables -A INPUT -p tcp --dport 22 -m state --state NEW \
        -j LOG --log-prefix "[SSH-ATTEMPT] " --log-level 4

    # Rate-limit: allow max 5 new SSH connections per minute per source IP
    rule_explain \
        "iptables ... -m recent --update --seconds 60 --hitcount 5 -j LOG" \
        "After 5 connections in 60s from same IP, log as potential brute-force"
    iptables -A INPUT -p tcp --dport 22 -m state --state NEW \
        -m recent --name SSH --set
    iptables -A INPUT -p tcp --dport 22 -m state --state NEW \
        -m recent --name SSH --update --seconds 60 --hitcount 5 \
        -j LOG --log-prefix "[BRUTEFORCE-DETECT] " --log-level 4

    # Still accept all SSH (just log it)
    iptables -A INPUT -p tcp --dport 22 -j ACCEPT

    echo "[MODERATE] Rate-limit + logging active. Brute-force is visible but allowed."
    iptables -L INPUT -n -v
    exit 0
fi

# ---------------------------------------------------------------------------
# Phase: HARDENED — blocks brute-force, key auth only recommended
# ---------------------------------------------------------------------------
if [ "$PHASE" = "hardened" ]; then
    echo "[HARDENED] Applying full hardening rules"
    iptables -F INPUT
    iptables -F OUTPUT

    # Default policy: drop all, allow explicitly
    rule_explain \
        "iptables -P INPUT DROP" \
        "Default deny: any traffic not explicitly allowed is dropped"
    iptables -P INPUT DROP
    iptables -P FORWARD DROP

    # Allow established sessions
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

    # Allow loopback
    iptables -A INPUT -i lo -j ACCEPT

    # Allow ICMP ping (useful for lab testing)
    iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT

    # Allow SSH from the monitor network only (whitelist by subnet)
    rule_explain \
        "iptables -A INPUT -s 192.168.100.0/24 -p tcp --dport 22 -j ACCEPT" \
        "Only allow SSH from the trusted monitor network — deny from attack-net"
    iptables -A INPUT -s 192.168.100.0/24 -p tcp --dport 22 \
        -j LOG --log-prefix "[SSH-ALLOWED] "
    iptables -A INPUT -s 192.168.100.0/24 -p tcp --dport 22 -j ACCEPT

    # Block SSH from attack network
    rule_explain \
        "iptables -A INPUT -s 172.20.0.0/24 -p tcp --dport 22 -j DROP" \
        "Block SSH from the attack network — attacker cannot brute-force"
    iptables -A INPUT -s 172.20.0.0/24 -p tcp --dport 22 \
        -j LOG --log-prefix "[SSH-BLOCKED] "
    iptables -A INPUT -s 172.20.0.0/24 -p tcp --dport 22 -j DROP

    # Hard rate-limit: max 3 new connections per 60s (last resort)
    iptables -A INPUT -p tcp --dport 22 -m state --state NEW \
        -m recent --name SSH --set
    iptables -A INPUT -p tcp --dport 22 -m state --state NEW \
        -m recent --name SSH --update --seconds 60 --hitcount 3 \
        -j LOG --log-prefix "[RATELIMIT-DROP] "
    iptables -A INPUT -p tcp --dport 22 -m state --state NEW \
        -m recent --name SSH --update --seconds 60 --hitcount 3 \
        -j DROP

    echo "[HARDENED] Brute-force from attack network is now blocked."
    echo "[HARDENED] SSH only accessible from monitor network (192.168.100.0/24)"
    iptables -L INPUT -n -v
    exit 0
fi

# ---------------------------------------------------------------------------
# Phase: DEMO — explain all concepts
# ---------------------------------------------------------------------------
echo ""
echo "CONCEPT: iptables chains"
echo "  INPUT   — packets destined for THIS machine"
echo "  OUTPUT  — packets leaving this machine"
echo "  FORWARD — packets passing THROUGH this machine (routing)"
echo ""
echo "CONCEPT: targets"
echo "  ACCEPT  — let the packet through"
echo "  DROP    — silently discard (attacker gets no feedback)"
echo "  REJECT  — discard and send error back"
echo "  LOG     — write to syslog and continue evaluating rules"
echo ""
echo "CONCEPT: stateful matching (-m state)"
echo "  NEW         — first packet of a new connection"
echo "  ESTABLISHED — part of an already-accepted connection"
echo "  RELATED     — related to an established connection (e.g. FTP data)"
echo ""
echo "CONCEPT: rate limiting (-m recent)"
echo "  --set                  remember this IP"
echo "  --update --seconds 60  check if IP was seen in last 60 seconds"
echo "  --hitcount 5           how many times before firing"
echo ""
echo "CONCEPT: network segmentation"
echo "  -s 172.20.0.0/24       match traffic FROM this subnet"
echo "  -d 10.10.0.0/24        match traffic TO this subnet"
echo "  Blocking FORWARD chain prevents routing between networks"
echo ""
echo "Run with a phase argument to apply rules:"
echo "  bash /lab/firewall_setup.sh weak"
echo "  bash /lab/firewall_setup.sh moderate"
echo "  bash /lab/firewall_setup.sh hardened"
