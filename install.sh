#!/bin/bash
# install_lab_deps.sh - Install dependencies for the SSH Brute-Force & Botnet Lab on Kali Linux
# Usage: sudo bash install_lab_deps.sh

set -e
trap 'echo "[ERROR] Script failed at line $LINENO. Check output above."' ERR

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [ "$EUID" -ne 0 ]; then
    log_error "Please run as root (use sudo)."
    exit 1
fi

if [ -n "$SUDO_USER" ]; then
    USER_HOME=$(eval echo ~$SUDO_USER)
    REAL_USER=$SUDO_USER
else
    log_error "Cannot determine original user. Run with sudo."
    exit 1
fi

log_info "Updating package lists..."
apt update -y

log_info "Installing system packages..."
apt install -y \
    podman \
    podman-compose \
    python3 \
    git \
    openssh-client \
    netcat-openbsd \
    tcpdump \
    iptables \
    dnsutils \
    curl \
    vim \
    htop

# Verify podman
if ! command -v podman &> /dev/null; then
    log_error "podman not found."
    exit 1
fi
log_info "podman version: $(podman --version)"

# Verify podman-compose (installed via apt)
if ! command -v podman-compose &> /dev/null; then
    log_warn "podman-compose not found, trying to install via pipx..."
    apt install -y pipx
    pipx ensurepath
    pipx install podman-compose
    export PATH="$USER_HOME/.local/bin:$PATH"
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$USER_HOME/.bashrc"
fi
log_info "podman-compose version: $(podman-compose --version 2>/dev/null || echo 'unknown')"

# Lab directory
LAB_DIR="$USER_HOME/Documents/ssh-botnet-lab"
if [ ! -d "$LAB_DIR" ]; then
    log_info "Cloning lab repository..."
    sudo -u "$REAL_USER" mkdir -p "$USER_HOME/Documents"
    sudo -u "$REAL_USER" git clone https://github.com/your-org/ssh-botnet-lab.git "$LAB_DIR" || {
        log_warn "Clone failed. Please place lab files manually in $LAB_DIR"
    }
else
    log_info "Lab directory already exists at $LAB_DIR"
fi

if [ -f "$LAB_DIR/setup.sh" ]; then
    chmod +x "$LAB_DIR/setup.sh"
    log_info "setup.sh is executable"
else
    log_warn "setup.sh not found in $LAB_DIR"
fi

# Rootless podman setup
log_info "Configuring rootless podman for user $REAL_USER"
sudo -u "$REAL_USER" podman system migrate 2>/dev/null || true

log_info "Verification:"
sudo -u "$REAL_USER" podman ps &>/dev/null && log_info "  podman rootless works" || log_warn "  podman rootless may need additional setup (run 'podman system migrate' as $REAL_USER)"

log_info "All dependencies installed successfully."
log_info "Next steps:"
echo "  1. Log out and back in (or source ~/.bashrc) to update PATH."
echo "  2. cd $LAB_DIR"
echo "  3. ./setup.sh"
echo "  4. Follow the lab guide."
exit 0
