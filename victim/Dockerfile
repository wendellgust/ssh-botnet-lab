FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y \
    openssh-server \
    python3 \
    fail2ban \
    net-tools iproute2 iputils-ping iptables \
  && rm -rf /var/lib/apt/lists/*
RUN useradd --no-log-init -m -s /bin/bash labuser && echo "labuser:password123" | chpasswd && \
    useradd --no-log-init -m -s /bin/bash admin   && echo "admin:admin"         | chpasswd && \
    useradd --no-log-init -m -s /bin/bash deploy  && echo "deploy:deploy123"    | chpasswd && \
    echo "root:toor" | chpasswd
COPY firewall_setup.sh /lab/firewall_setup.sh
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /lab/firewall_setup.sh /entrypoint.sh
RUN mkdir -p /var/log
EXPOSE 22
CMD ["/entrypoint.sh"]
