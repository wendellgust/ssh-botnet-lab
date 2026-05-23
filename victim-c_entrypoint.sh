#!/bin/bash
# =============================================================================
# victim-c entrypoint
# Creates users at RUNTIME (not build time) to avoid Podman rootless's
# exit-status-9 SIGKILL on useradd-in-Dockerfile.
# =============================================================================

set -u

# ── Create users (runtime, not build) ─────────────────────────────────────────
# Wrapped in a loop with || true so a partial failure doesn't abort sshd start.
for entry in "labuser:deepnet123:1001" "operator:operator1:1002"; do
    user="${entry%%:*}"
    rest="${entry#*:}"
    pass="${rest%%:*}"
    uid="${rest#*:}"

    if ! id "$user" &>/dev/null; then
        useradd --no-log-init -u "$uid" -m -s /bin/bash "$user" 2>/dev/null \
        || useradd --no-log-init -u "$uid" -M -s /bin/bash "$user" 2>/dev/null \
        || true

        # Ensure home exists even if -m was skipped
        mkdir -p "/home/$user"
        chown "$uid:$uid" "/home/$user" 2>/dev/null || true
    fi
    echo "$user:$pass" | chpasswd
done

# Root password
echo "root:rootdeep" | chpasswd

# ── sshd_config (same hardening as the rest of the lab) ──────────────────────
cat > /etc/ssh/sshd_config << 'SSHEOF'
Port 22
ListenAddress 0.0.0.0
Protocol 2

HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_ed25519_key

PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
ChallengeResponseAuthentication no
UsePAM no

MaxStartups 50:30:100
MaxAuthTries 6
LoginGraceTime 30

LogLevel INFO
PrintMotd no
PrintLastLog no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
SSHEOF

# ── Host keys ─────────────────────────────────────────────────────────────────
ssh-keygen -A 2>/dev/null || true

# ── Log file ──────────────────────────────────────────────────────────────────
mkdir -p /run/sshd /var/log /var/log/lab
touch /var/log/auth.log
chmod 644 /var/log/auth.log

echo "[victim-c entrypoint] users created, starting sshd..."

# ── sshd in the foreground, logging to auth.log ──────────────────────────────
exec /usr/sbin/sshd -D -e 2>> /var/log/auth.log
