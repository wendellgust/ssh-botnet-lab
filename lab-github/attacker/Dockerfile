# =============================================================================
# Attacker / Botnet Simulator Container
# Ubuntu-based, contains only Python simulation tools
# NO real attack tools (no hydra, no metasploit, no nmap raw scanning)
# All "attacks" are simulated via Python scripts for detection engineering
# =============================================================================

FROM ubuntu:22.04

LABEL maintainer="SSH Botnet Lab — Educational Use Only"
LABEL description="Botnet simulation container — runs Python scripts only"

ENV DEBIAN_FRONTEND=noninteractive
ENV LAB_WARNING="THIS CONTAINER IS FOR ISOLATED LAB USE ONLY"

# Install everything via apt — no pip needed, avoids internet access issues
RUN apt-get update && apt-get install -y \
    python3 \
    python3-paramiko \
    python3-requests \
    openssh-client \
    netcat-openbsd \
    iputils-ping \
    net-tools \
    iproute2 \
    tcpdump \
    curl \
  && rm -rf /var/lib/apt/lists/*

# Create a non-root lab user
RUN useradd -m -s /bin/bash labuser

# Copy simulation scripts
COPY simulator.py /lab/simulator.py
COPY entrypoint.sh /lab/entrypoint.sh
RUN chmod +x /lab/entrypoint.sh

WORKDIR /lab

CMD ["/lab/entrypoint.sh"]
