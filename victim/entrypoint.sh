#!/bin/bash
# Create /run/sshd — required by OpenSSH privilege separation
mkdir -p /run/sshd /var/log

# Generate host keys if missing
ssh-keygen -A 2>/dev/null

# Write sshd config directly — overrides anything in the image
# UsePAM no  = critical for Podman rootless (PAM breaks without systemd)
# MaxStartups 50 = prevents throttling during brute-force simulation
cat > /etc/ssh/sshd_config << 'CONF'
Port 22
PermitRootLogin yes
PasswordAuthentication yes
UsePAM no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
PrintMotd no
LogLevel VERBOSE
AuthorizedKeysFile .ssh/authorized_keys
MaxStartups 50
CONF

touch /var/log/auth.log

# exec = sshd becomes PID 1, container lives as long as sshd lives
# -e   = log to stderr, redirected to auth.log
exec /usr/sbin/sshd -D -e 2>> /var/log/auth.log
