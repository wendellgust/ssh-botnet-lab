FROM ubuntu:22.04

LABEL description="Attacker container — botnet simulator"

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    python3 \
    python3-paramiko \
    python3-requests \
    openssh-client \
    netcat-openbsd \
    iputils-ping \
    net-tools \
    iproute2 \
    curl \
  && rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash labuser

COPY simulator.py /lab/simulator.py
COPY entrypoint.sh /lab/entrypoint.sh
RUN chmod +x /lab/entrypoint.sh

WORKDIR /lab
CMD ["/lab/entrypoint.sh"]
