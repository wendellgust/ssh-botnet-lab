#!/bin/bash
# =============================================================================
# Firewall Setup Script — Lab Victim Containers
# Run inside victim1: bash /lab/firewall_setup.sh [phase]
# Phases: weak | moderate | hardened | demo
# =============================================================================

PHASE="${1:-demo}"
echo "============================================================"
echo " Firewall Setup — Phase: $PHASE"
echo "============================================================"

if [ "$PHASE" = "weak" ]; then
    echo "[WEAK] Flushing all firewall rules"
    iptables -F INPUT
    iptables -F OUTPUT
    iptables -F FORWARD
    iptables -P INPUT ACCEPT
    iptables -P OUTPUT ACCEPT
    iptables -P FORWARD ACCEPT
    echo "[WEAK] No firewall. Brute-force will succeed."
    exit 0
fi

if [ "$PHASE" = "moderate" ]; then
    echo "[MODERATE] Applying rate-limit and logging rules"
    iptables -F INPUT
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    echo "  RULE: iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT"
    echo "  WHY:  Allow traffic that is part of an already-established session"
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A INPUT -p tcp --dport 22 -m state --state NEW \
        -j LOG --log-prefix "[SSH-ATTEMPT] " --log-level 4
    echo "  RULE: iptables -A INPUT -p tcp --dport 22 -m state --state NEW -j LOG"
    echo "  WHY:  Log every new SSH connection attempt — feeds detection rules"
    iptables -A INPUT -p tcp --dport 22 -m state --state NEW \
        -m recent --name SSH --set
    iptables -A INPUT -p tcp --dport 22 -m state --state NEW \
        -m recent --name SSH --update --seconds 60 --hitcount 5 \
        -j LOG --log-prefix "[BRUTEFORCE-DETECT] " --log-level 4
    echo "  RULE: iptables ... -m recent --update --seconds 60 --hitcount 5 -j LOG"
    echo "  WHY:  After 5 connections in 60s from same IP, log as potential brute-force"
    iptables -A INPUT -p tcp --dport 22 -j ACCEPT
    echo "[MODERATE] Rate-limit + logging active. Brute-force is visible but allowed."
    echo "[MODERATE] Check logs inside this container: dmesg | grep BRUTEFORCE"
    exit 0
fi

if [ "$PHASE" = "hardened" ]; then
    echo "[HARDENED] Applying full hardening rules"
    iptables -F INPUT
    iptables -F OUTPUT
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT
    iptables -A INPUT -s 172.20.0.0/24 -p tcp --dport 22 \
        -j LOG --log-prefix "[SSH-BLOCKED] "
    iptables -A INPUT -s 172.20.0.0/24 -p tcp --dport 22 -j DROP
    iptables -A INPUT -s 172.21.0.0/24 -p tcp --dport 22 \
        -j LOG --log-prefix "[SSH-BLOCKED] "
    iptables -A INPUT -s 172.21.0.0/24 -p tcp --dport 22 -j DROP
    iptables -A INPUT -p tcp --dport 22 -m state --state NEW \
        -m recent --name SSH --set
    iptables -A INPUT -p tcp --dport 22 -m state --state NEW \
        -m recent --name SSH --update --seconds 60 --hitcount 3 \
        -j LOG --log-prefix "[RATELIMIT-DROP] "
    iptables -A INPUT -p tcp --dport 22 -m state --state NEW \
        -m recent --name SSH --update --seconds 60 --hitcount 3 \
        -j DROP
    echo "[HARDENED] SSH from attack networks is now blocked."
    echo "[HARDENED] Reset with: bash /lab/firewall_setup.sh weak"
    iptables -L INPUT -n -v
    exit 0
fi

echo ""
echo "Usage: bash /lab/firewall_setup.sh [weak|moderate|hardened]"
echo ""
echo "  weak      — no rules (default lab state, brute-force works)"
echo "  moderate  — rate-limit + logging (detection without blocking)"
echo "  hardened  — block attack network, rate-limit everything else"
echo ""
echo "Concepts:"
echo "  DROP    — silently discard (attacker gets no feedback)"
echo "  REJECT  — discard + send error (faster for attacker to know)"
echo "  LOG     — write to kernel log, check with: dmesg | grep SSH"
echo "  -m recent — track connection counts per IP over a time window"
