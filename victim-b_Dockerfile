FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y \
    openssh-server \
    python3 \
    fail2ban \
    net-tools iproute2 iputils-ping iptables \
  && rm -rf /var/lib/apt/lists/*
RUN useradd --no-log-init -m -s /bin/bash labuser    && echo "labuser:internal123" | chpasswd && \
    useradd --no-log-init -m -s /bin/bash svcaccount && echo "svcaccount:service1" | chpasswd && \
    echo "root:rootpass" | chpasswd
COPY honeypot_logger.py /lab/honeypot_logger.py
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
RUN mkdir -p /var/log /var/log/lab
EXPOSE 22
CMD ["/entrypoint.sh"]
