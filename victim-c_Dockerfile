FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y \
    openssh-server python3 fail2ban \
    net-tools iproute2 iputils-ping iptables \
  && rm -rf /var/lib/apt/lists/*
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
RUN mkdir -p /var/log /var/log/lab /run/sshd
EXPOSE 22
CMD ["/entrypoint.sh"]
