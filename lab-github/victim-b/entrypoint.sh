#!/bin/bash
mkdir -p /var/log /run/sshd /var/log/lab
ssh-keygen -A 2>/dev/null
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
touch /var/log/auth.log /var/log/lab/honeypot_events.jsonl
python3 /lab/honeypot_logger.py &
exec /usr/sbin/sshd -D -e 2>> /var/log/auth.log
