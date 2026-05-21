# =============================================================================
# Victim Container — Network A (172.20.0.0/24)
# Ubuntu with OpenSSH — intentionally weak config for lab purposes
# =============================================================================

FROM ubuntu:22.04

LABEL description="Lab victim container — SSH server with intentional weaknesses"

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    openssh-server \
    rsyslog \
    python3 \
    net-tools \
    iproute2 \
    iputils-ping \
    iptables \
  && rm -rf /var/lib/apt/lists/*

# Create intentionally weak lab accounts
RUN useradd -m -s /bin/bash labuser && \
    echo "labuser:password123" | chpasswd && \
    useradd -m -s /bin/bash admin && \
    echo "admin:admin" | chpasswd && \
    useradd -m -s /bin/bash deploy && \
    echo "deploy:deploy123" | chpasswd && \
    echo "root:toor" | chpasswd

COPY sshd_config /etc/ssh/sshd_config
COPY rsyslog.conf /etc/rsyslog.conf
COPY firewall_setup.sh /lab/firewall_setup.sh
COPY entrypoint.sh /entrypoint.sh

RUN mkdir -p /run/sshd /var/log/lab && \
    chmod +x /lab/firewall_setup.sh /entrypoint.sh

EXPOSE 22
CMD ["/entrypoint.sh"]
