FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y \
    openssh-server python3 fail2ban \
    net-tools iproute2 iputils-ping iptables \
  && rm -rf /var/lib/apt/lists/*
RUN useradd -m -s /bin/bash labuser    && echo "labuser:deepnet123"  | chpasswd && \
    useradd -m -s /bin/bash operator   && echo "operator:operator1"  | chpasswd && \
    echo "root:rootdeep" | chpasswd
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
RUN mkdir -p /var/log /var/log/lab
EXPOSE 22
CMD ["/entrypoint.sh"]
