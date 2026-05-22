#!/bin/bash
# install.sh – Install dependencies for SSH Brute-Force & Botnet Lab on Kali
# Usage: sudo bash install.sh

set -e
trap 'echo "[ERROR] Failed at line $LINENO. Check output above."' ERR

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check root
if [ "$EUID" -ne 0 ]; then
    log_error "Please run as root (use sudo)."
    exit 1
fi

# Get original user
if [ -n "$SUDO_USER" ]; then
    USER_HOME=$(eval echo ~$SUDO_USER)
    REAL_USER=$SUDO_USER
else
    log_error "Cannot determine original user. Run with sudo."
    exit 1
fi

log_info "Updating package list..."
apt update -y

log_info "Installing core packages: podman, podman-compose, git, tools..."
apt install -y \
    podman \
    podman-compose \
    git \
    openssh-client \
    netcat-openbsd \
    tcpdump \
    iptables \
    dnsutils \
    curl \
    vim \
    htop

# Install podman-docker (provides /usr/bin/docker shim for podman)
log_info "Installing podman-docker for Docker compatibility..."
apt install -y podman-docker

# Install pipx and use it to install docker-compose (safe, no system Python conflict)
if ! command -v docker-compose &> /dev/null; then
    log_info "Installing docker-compose via pipx..."
    apt install -y pipx
    pipx ensurepath
    pipx install docker-compose
    # Force PATH update for current session
    export PATH="$USER_HOME/.local/bin:$PATH"
    # Also add to bashrc for future sessions
    sudo -u "$REAL_USER" bash -c "grep -q '.local/bin' ~/.bashrc || echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc"
fi

# Verify docker-compose is available
if ! command -v docker-compose &> /dev/null; then
    log_error "docker-compose still not found. Try logging out and back in, then rerun."
    exit 1
fi
log_info "docker-compose version: $(docker-compose --version)"

# Verify podman + docker shim
if ! command -v docker &> /dev/null; then
    log_warn "'docker' command not found. podman-docker may not be linked correctly."
    log_warn "Create symlink: ln -s /usr/bin/podman /usr/local/bin/docker"
    ln -sf /usr/bin/podman /usr/local/bin/docker
fi
log_info "podman version: $(podman --version)"

# Setup rootless podman for the real user
log_info "Configuring rootless podman for $REAL_USER..."
sudo -u "$REAL_USER" podman system migrate 2>/dev/null || true

# Clone lab repo if not present
LAB_DIR="$USER_HOME/Documents/ssh-botnet-lab"
if [ ! -d "$LAB_DIR" ]; then
    log_info "Cloning lab repository..."
    sudo -u "$REAL_USER" mkdir -p "$USER_HOME/Documents"
    sudo -u "$REAL_USER" git clone https://github.com/your-org/ssh-botnet-lab.git "$LAB_DIR" || {
        log_warn "Git clone failed. Please manually place lab files in $LAB_DIR"
    }
else
    log_info "Lab directory already exists at $LAB_DIR"
fi

if [ -f "$LAB_DIR/setup.sh" ]; then
    chmod +x "$LAB_DIR/setup.sh"
    log_info "setup.sh is now executable"
else
    log_warn "setup.sh not found in $LAB_DIR. The lab may be incomplete."
fi

# Final checks
log_info "Verifying compose command detection:"
if sudo -u "$REAL_USER" bash -c "cd $LAB_DIR; command -v docker-compose &>/dev/null || command -v podman-compose &>/dev/null"; then
    log_info "✓ Compose command is available"
else
    log_warn "Neither docker-compose nor podman-compose found in user's PATH. Try logging out and back in."
fi

log_info "All dependencies installed successfully."
log_info "Next steps:"
echo "  1. Log out and back in (or source ~/.bashrc) to update PATH."
echo "  2. cd $LAB_DIR"
echo "  3. ./setup.sh"
echo "  4. Follow the lab guide."
exit 0
