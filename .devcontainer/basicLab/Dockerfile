FROM mcr.microsoft.com/devcontainers/base:ubuntu

# Base packages
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y \
  python3 python3-pip iproute2 iputils-ping curl wget jq xz-utils gzip ca-certificates \
  && rm -rf /var/lib/apt/lists/*

# Ansible + AVD
RUN pip3 install --no-cache-dir ansible arista.avd