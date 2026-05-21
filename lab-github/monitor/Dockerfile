FROM ubuntu:22.04

LABEL description="Lab monitor — log collection and detection analysis"

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    python3 \
    tcpdump \
    net-tools \
    iproute2 \
    iputils-ping \
    jq \
  && rm -rf /var/lib/apt/lists/*

COPY analyzer.py /lab/monitor/analyzer.py
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

RUN mkdir -p /var/log/lab

WORKDIR /lab/monitor

CMD ["/entrypoint.sh"]
