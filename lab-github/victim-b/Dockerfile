FROM ubuntu:22.04

LABEL description="Internal victim / honeypot — Network B, only reachable via pivot"

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    openssh-server \
    python3 \
    net-tools \
    iproute2 \
    iputils-ping \
    iptables \
  && rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash labuser && \
    echo "labuser:internal123" | chpasswd && \
    useradd -m -s /bin/bash svcaccount && \
    echo "svcaccount:service1" | chpasswd && \
    echo "root:rootpass" | chpasswd

COPY honeypot_logger.py /lab/honeypot_logger.py
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

RUN mkdir -p /run/sshd /var/log /var/log/lab

EXPOSE 22
CMD ["/entrypoint.sh"]
