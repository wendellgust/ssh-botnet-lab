#!/bin/bash
# /run/sshd required by OpenSSH privilege separation
mkdir -p /run/sshd /var/log

# Generate host keys
ssh-keygen -A 2>/dev/null

# Write sshd config with all Podman rootless fixes baked in
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

# exec = sshd is PID 1, logs stderr to auth.log
exec /usr/sbin/sshd -D -e 2>> /var/log/auth.log
