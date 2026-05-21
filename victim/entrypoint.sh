#!/bin/bash
# /run/sshd must exist for OpenSSH privilege separation chroot
mkdir -p /run/sshd /var/log

# Generate host keys
ssh-keygen -A 2>/dev/null

# Write sshd config — all known fixes for Podman rootless
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

# exec = sshd is PID 1, logs to stderr -> auth.log
exec /usr/sbin/sshd -D -e 2>> /var/log/auth.log
